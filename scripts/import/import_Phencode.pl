#!/usr/bin/env perl

## extract data from local phencode database
##   - run QC
##   - import to ensembl schema
##   - create variation set

## requires seq_region table and attribs

## crudely glued together from 2 initial scripts

use strict;
use warnings;
use Getopt::Long;


use Bio::DB::Fasta;
use Bio::EnsEMBL::Registry;
use Bio::EnsEMBL::Variation::VariationFeature;
use Bio::EnsEMBL::Variation::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Variation::DBSQL::VariationFeatureAdaptor;
use Bio::EnsEMBL::Utils::Sequence qw(reverse_comp );
use Bio::EnsEMBL::Variation::Utils::Sequence qw( get_hgvs_alleles);
use Bio::EnsEMBL::Variation::Utils::QCUtils qw( check_four_bases get_reference_base check_illegal_characters check_for_ambiguous_alleles remove_ambiguous_alleles find_ambiguous_alleles check_variant_size summarise_evidence count_rows count_group_by);

my ($registry_file,  $fasta_file);

GetOptions ( 
             "fasta=s"       => \$fasta_file,
             "registry=s"    => \$registry_file,
    );

usage() unless defined $registry_file && defined $fasta_file ;

### write to and read from tmp file
our $DATA_FILE = "phencode_data_QC.txt";

my $reg = 'Bio::EnsEMBL::Registry';
$reg->load_all($registry_file);

my $varfeat_adaptor   = $reg->get_adaptor('homo_sapiens', 'variation', 'variationfeature');
my $variation_adaptor = $reg->get_adaptor('homo_sapiens', 'variation', 'variation');
my $allele_adaptor    = $reg->get_adaptor('homo_sapiens', 'variation', 'allele');


## create index on fasta for reference check or reference allele determination
my $db = Bio::DB::Fasta->new( $fasta_file );
  
## writes all data to a file to allow checking & returns the number of times each name is seen
my $var_counts = extract_data();

## find or enter source info
my %source_data  = ( "name"    => "PhenCode",
                     "version" => "14-Nov-2012",
                     "desc"    => "PhenCode is a collaborative project to better understand the relationship between genotype and phenotype in humans",
                     "url"     => "http://phencode.bx.psu.edu/",
                     "somatic" => 0
    );

my $source_id = get_source($varfeat_adaptor->dbc,  \%source_data );

## get seq_region_ids for quick variation_feature creation
my $seq_ids   = get_seq_ids($varfeat_adaptor->dbc );


## read the file just written  & enter data 
my %new_var;
open my $infile, $DATA_FILE ||die "Failed to open data file to read : $!\n";
while(<$infile>){

    chomp;

    my @a = split/\t/;

    ## ~40 with same name, different locations (in repeat) - skip these
    next if  $var_counts->{$a[0]} > 1;

    if ($a[5] eq "-1" && $a[1] !~/Phencode|del|ins/i){
        ## compliment individual alleles keeping ref/alt order
	my @al = split(/\//,$a[1]);
        $a[1] = '';
	foreach my $al(@al){
	    reverse_comp(\$al) ;
	    $a[1] .= $al . "/";
	}
	$a[1] =~ s/\/$//;
        $a[5] = 1;
    }


    my $var = enter_var(\@a, 
                        $variation_adaptor,
                        $source_id 
        );
    ## save var ids to add to variation_set later
    $new_var{$var->dbID()} = 1;

    enter_varfeat(\@a, 
                  $varfeat_adaptor,
                  $source_id,
                  $var,
                  $seq_ids
        );
    
    enter_alleles(\@a,
                  $allele_adaptor,
                  $var
        );
  
}

## add all var to phencode set
add_to_set( $varfeat_adaptor->dbc, \%new_var);

## export data from local Phencode database and run QC checks
## write tmp file for checking
sub extract_data{


    my $dbh = DBI->connect('dbi:mysql:phencode:ens-variation2:3306', 'ensadmin', 'ensembl', undef);
    
    my $variant_ext_sth = $dbh->prepare(qq[ SELECT gv.id,
                                              gv.name,
                                              map.label,
                                              map.chrom,
                                              map.chromStart,
                                              map.chromEnd,
                                              map.strand,
                                              gv.srcId                                                 
                                        FROM gv, gvPosHg19 map 
                                        WHERE gv.id = map.name
                                        ]);       
    

    open my $out, ">$DATA_FILE"|| die "Failed to open data file to write: $!\n";
    my %count;
   
    $variant_ext_sth->execute() ||die;
    my $data = $variant_ext_sth->fetchall_arrayref();
    
    
    foreach my $l (@{$data}){
        
        ## skip unless hgvs in DNA terms  
        next unless $l->[2] =~ /\:g|\:c/;
        
        $l->[3] =~ s/chr//;
        $l->[4]++;
        
        ## hgvs but on non-reference seq => switch seq name & coords
        my ($reported_seq,$change) = split(/\:g|\:c\./,$l->[2], 2);
        
        ### sort out alleles 
        ##$change =~ s/g\.|\[|\]|\.//g;  ## clean up  D87675.1(APP):g.[..g.278645G>T..]  half fail anyway
        my ($ref_allele, $alt_allele);
        
        eval{
            ($ref_allele, $alt_allele) = get_hgvs_alleles( $l->[2] );
        };
        if($@){
            warn "skipping $l->[2]  - $@\n";
            next;
        }
        ## inserted bases may not be supplied
        $alt_allele = "PhenCode_variation" if $change =~/ins/ && ! $alt_allele ;
        
        ## take deletion from reference
        if ($change =~/del/  && ! $ref_allele ){
            $ref_allele =  $db->seq($l->[3], $l->[4], $l->[5]) ;
            reverse_comp(\$ref_allele )if $l->[6] eq "-";
        }
        unless (defined $ref_allele && defined $alt_allele){
            warn "Skipping $l->[2] from $l->[7] as could not determine alleles\n";
            next;
        }
        my $len = length($ref_allele);
        $ref_allele = "$len\_base_deletion" if ($len > 4000);
        my $allele_string = "$ref_allele/$alt_allele";
        
        
        
        my $start = $l->[4];
        my $end   = $l->[5];
        if($change =~/ins/ && $change !~/del/ ){
            ($start, $end) = ($end, $start);
        }
        $start = $end + 1 if $change =~/dup/ ;
        
        my $strand ;
        if ($l->[6] eq "+"){
            $strand = 1;
        }
        elsif ($l->[6] eq "-"){
            $strand = -1;
        }
        else{
            die "Unknown strand: $l->[6] \n";
        }

        my %var = ( "start"       =>  $start, 
                    "end"         =>  $end,
                    "strand"      =>  $strand, 
                    "seqreg_name" =>  $l->[3], 
                    "allele"      =>  $allele_string,
                    "label"       =>  $l->[2], 
                    "name"        =>  $l->[0],
		    "source"      =>  $l->[7],

        );
        ## check for duplicates
        $count{$l->[0]}++;
	$var{fail_reasons} = " ";
        unless  ($ref_allele =~/_base_deletion/){  ## can't do much with these
            $var{fail_reasons} = run_checks(\%var);
        }

        ## print to tmp file 
        print $out "$var{name}\t$var{allele}\t$var{seqreg_name}\t$var{start}\t$var{end}\t$var{strand}\t$var{label}\t$var{source}\t$var{fail_reasons}\n";
    }

    close $out;
    return \%count;

}

## call standard QC checks & return string of failure reasons
sub run_checks{
    
    my $var = shift;
    
    my @fail;
    
    ## Type 3  flag variation as fail if it has [A/T/G/C] allele string 
        
    my $all_possible_check = check_four_bases($var->{allele});
    push @fail, 3 if ($all_possible_check ==1);
    
    ## Type 14 resolve ambiguities before reference check - flag variants & alleles as fails
    
    my $is_ambiguous = check_for_ambiguous_alleles( $var->{allele} );
    push @fail, 14  if(defined $is_ambiguous) ;
    
    
    # Extract reference sequence to run ref checks [ compliments for reverse strand multi-mappers]    
    
    my $ref_seq = get_reference_base($var, $db, "fasta_seq") ;
    
    unless(defined $ref_seq){ 
        ## don't check further if obvious coordinate error
        push @fail, 15;
	
	return ( join",", @fail );    
    }

    
    ## is ref base in agreement?
    my $exp_ref = (split/\//, $var->{allele} )[0] ; 
    push @fail, 2 unless "\U$exp_ref" eq "\U$ref_seq"; ## using soft masked seq
       
    
    ## is either allele of compatible length with given coordinates?
    my $ref = (split/\//, $var->{allele} )[0];
    my $match_coord_length = check_variant_size( $var->{start}, $var->{end}, $ref);
    push @fail, 15 unless  ($match_coord_length == 1);
    
    
    return (join",", @fail);
}


## look up or insert source
sub get_source {

    my $dbh         = shift;
    my $source_data = shift;


    my $source_ext_sth = $dbh->prepare(qq[ select source_id from source where name = ?]);
    my $source_ins_sth = $dbh->prepare(qq[insert into source (name, version, description, url, somatic_status) values (?,?,?,?,?) ]);

    ### source already loaded
    $source_ext_sth->execute($source_data->{name})||die;
    my $id = $source_ext_sth->fetchall_arrayref();

    return $id->[0]->[0] if defined $id->[0]->[0];

    ## add new source
    $source_ins_sth->execute($source_data->{name}, $source_data->{version}, $source_data->{desc}, $source_data->{url}, $source_data->{somatic} )||die;
    $source_ext_sth->execute($source_data->{name})||die;
    my $idn = $source_ext_sth->fetchall_arrayref();
    
    return $idn->[0]->[0] if defined $idn->[0]->[0];

    die "Failed to get source for $source_data->{name} \n";

}
 
## look up seq region ids for quick variation_feature creation
sub get_seq_ids{

    my $dbh = shift;

    my %seq_ids;

    my $seq_ext_sth = $dbh->prepare(qq[ select seq_region_id, name from seq_region]);
    $seq_ext_sth->execute();
    my $dat = $seq_ext_sth->fetchall_arrayref();

    foreach my $l(@{$dat}){
        $seq_ids{$l->[1]} = $l->[0];
    }

    return \%seq_ids;
}

sub enter_var{

    my $line    = shift;
    my $adaptor = shift;
    my $source  = shift;

    my $var = Bio::EnsEMBL::Variation::Variation->new_fast({
        name             => $line->[0],
        source_id        => $source_id,
        is_somatic       => 0
                                                           });

    $adaptor->store($var);

    if(defined $line->[8] && $line->[8] =~ /\d+/){
        ## add fail status
        my @fails;
        if( $line->[8] =~/\,/){  @fails = split /\,/, $line->[8];}
        else{ push @fails , $line->[8] ;} 
        my $var_id = $var->dbID();

        foreach my $type (@fails){
               warn "Adding fail infor var:$var_id, reason:$type\n";
               $adaptor->dbc->do(qq[ insert into failed_variation (variation_id, failed_description_id) values ($var_id, $type ) ]);
         }
    }
    return $var;
}

sub enter_varfeat{      

    my $line    = shift;
    my $adaptor = shift;
    my $source  = shift;
    my $var     = shift;
    my $seq_ids = shift;

    my $varfeat = Bio::EnsEMBL::Variation::VariationFeature->new_fast({
        variation_name   => $line->[0],
        source_id        => $source_id,
        allele_string    => $line->[1], 
        _variation_id    => $var->dbID(),                                          
        seq_region_id    => $seq_ids->{$line->[2]},
        start            => $line->[3],
        end              => $line->[4],
        strand           => $line->[5],
        is_somatic       => 0
                                                                      });

    $adaptor->store($varfeat);
}

sub enter_alleles{      

    my $line    = shift;
    my $adaptor = shift;
    my $var     = shift;

    my @alleles = split/\//, $line->[1];

    foreach my $allele (@alleles){

        my $allele_to_insert;
        my $len = length($allele);
        if($len > 100) { 
           $allele_to_insert = "$len\_base_deletion";
        }
        elsif(  $allele =~/deletion|insertion/){
           $allele_to_insert = $allele;
        }
        else{
           $allele_to_insert = "\U$allele";
        }
        my $al = Bio::EnsEMBL::Variation::Allele->new_fast({
            allele         =>$allele_to_insert ,
            variation      => $var
                                                           });
        $adaptor->store($al);

    }
}

## add variation ids to set
sub add_to_set{

    my ($dbh, $variation_ids ) = @_;

    my $set_id  = get_set($dbh);

    my $vsv_ins_sth = $dbh->prepare(qq[ insert ignore into  variation_set_variation
                                       (variation_id, variation_set_id)
                                        values (?,?)] );


    foreach my $var ( keys %{$variation_ids} ){
   
	$vsv_ins_sth->execute( $var, $set_id );
    }
}

## look up or enter variation set
sub get_set{

    my $dbh = shift;
    
    my $set_ext_sth = $dbh->prepare(qq[ select variation_set_id from variation_set where name ='PhenCode']);

    my $set_ins_sth = $dbh->prepare(qq[insert into variation_set (  name, description, short_name_attrib_id) 
                                        values ( 'PhenCode', 
                                       'Variants from the PhenCode Project',
                                        355) ]);

    ### look for old set record
    $set_ext_sth->execute();
    my $id = $set_ext_sth->fetchall_arrayref();

    return $id->[0]->[0] if defined $id->[0]->[0] ;


    ### enter new set record
    $set_ins_sth->execute(); 
    $set_ext_sth->execute();
    $id = $set_ext_sth->fetchall_arrayref();

    return $id->[0]->[0] if defined $id->[0]->[0] ;


    ### give up
    die "ERROR: variation set could not be entered\n"; 

}

sub usage{

    die "Usage:\n\timport_Phencode.pl  -fasta [genomic sequence file for QC] -registry [registry file]\n\n";
}
