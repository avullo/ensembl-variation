# Ensembl module for Bio::EnsEMBL::Variation::VariationFeature
#
# Copyright (c) 2004 Ensembl
#


=head1 NAME

Bio::EnsEMBL::Variation::VariationFeature - A genomic position for a nucleotide variation.

=head1 SYNOPSIS

    # Variation feature representing a single nucleotide polymorphism
    $vf = Bio::EnsEMBL::Variation::VariationFeature->new
       (-start   => 100,
        -end     => 100,
        -strand  => 1,
        -slice   => $slice,
        -allele_string => 'A/T',
        -variation_name => 'rs635421',
        -map_weight  => 1,
        -variation => $v);

    # Variation feature representing a 2bp insertion
    $vf = Bio::EnsEMBL::Variation::VariationFeature->new
       (-start   => 1522,
        -end     => 1521, # end = start-1 for insert
        -strand  => -1,
        -slice   => $slice,
        -allele_string => '-/AA',
        -variation_name => 'rs12111',
        -map_weight  => 1,
        -variation => $v2);

    ...

    # a variation feature is like any other ensembl feature, can be
    # transformed etc.
    $vf = $vf->transform('supercontig');

    print $vf->start(), "-", $vf->end(), '(', $vf->strand(), ')', "\n";

    print $vf->name(), ":", $vf->allele_string();

    # Get the Variation object which this feature represents the genomic
    # position of. If not already retrieved from the DB, this will be
    # transparently lazy-loaded
    my $v = $vf->variation();

=head1 DESCRIPTION

This is a class representing the genomic position of a nucleotide variation
from the ensembl-variation database.  The actual variation information is
represented by an associated Bio::EnsEMBL::Variation::Variation object. Some
of the information has been denormalized and is available on the feature for
speed purposes.  A VariationFeature behaves as any other Ensembl feature.
See B<Bio::EnsEMBL::Feature> and B<Bio::EnsEMBL::Variation::Variation>.

=head1 CONTACT

Post questions to the Ensembl development list: ensembl-dev@ebi.ac.uk

=head1 METHODS

=cut

use strict;
use warnings;

package Bio::EnsEMBL::Variation::VariationFeature;

use Bio::EnsEMBL::Feature;
use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::EnsEMBL::Utils::Argument  qw(rearrange);
use Bio::EnsEMBL::Utils::Sequence qw(reverse_comp); 
use Bio::EnsEMBL::Variation::Utils::Sequence qw(ambiguity_code variation_class hgvs_variant_notation);
use Bio::EnsEMBL::Variation::ConsequenceType;
use Bio::EnsEMBL::Variation::Variation;
use Bio::EnsEMBL::Slice;
use Bio::EnsEMBL::Variation::DBSQL::TranscriptVariationAdaptor;

our @ISA = ('Bio::EnsEMBL::Feature');

my %CONSEQUENCE_TYPES = %Bio::EnsEMBL::Variation::ConsequenceType::CONSEQUENCE_TYPES;

=head2 new

  Arg [-dbID] :
    see superclass constructor

  Arg [-ADAPTOR] :
    see superclass constructor

  Arg [-START] :
    see superclass constructor
  Arg [-END] :
    see superclass constructor

  Arg [-STRAND] :
    see superclass constructor

  Arg [-SLICE] :
    see superclass constructor

  Arg [-VARIATION_NAME] :
    string - the name of the variation this feature is for (denormalisation
    from Variation object).

  Arg [-MAP_WEIGHT] :
    int - the number of times that the variation associated with this feature
    has hit the genome. If this was the only feature associated with this
    variation_feature the map_weight would be 1.

  Arg [-VARIATION] :
    int - the variation object associated with this feature.

  Arg [-SOURCE] :
    string - the name of the source where the SNP comes from

  Arg [-VALIDATION_CODE] :
     reference to list of strings

  Arg [-CONSEQUENCE_TYPE] :
     string - highest consequence type for the transcripts of the VariationFeature

  Arg [-VARIATION_ID] :
    int - the internal id of the variation object associated with this
    identifier. This may be provided instead of a variation object so that
    the variation may be lazy-loaded from the database on demand.

  Example    :
    $vf = Bio::EnsEMBL::Variation::VariationFeature->new
       (-start   => 100,
        -end     => 100,
        -strand  => 1,
        -slice   => $slice,
        -allele_string => 'A/T',
        -variation_name => 'rs635421',
        -map_weight  => 1,
	-source  => 'dbSNP',
	-validation_code => ['cluster','doublehit'],
	-consequence_type => 'INTRONIC',
        -variation => $v);

  Description: Constructor. Instantiates a new VariationFeature object.
  Returntype : Bio::EnsEMBL::Variation::Variation
  Exceptions : none
  Caller     : general
  Status     : At Risk

=cut

sub new {
  my $caller = shift;
  my $class = ref($caller) || $caller;

  my $self = $class->SUPER::new(@_);
  my ($allele_str, $var_name, $map_weight, $variation, $variation_id, $source, $validation_code, $consequence_type) =
    rearrange([qw(ALLELE_STRING VARIATION_NAME 
                  MAP_WEIGHT VARIATION _VARIATION_ID SOURCE VALIDATION_CODE 
		  CONSEQUENCE_TYPE)], @_);

  $self->{'allele_string'}    = $allele_str;
  $self->{'variation_name'}   = $var_name;
  $self->{'map_weight'}       = $map_weight;
  $self->{'variation'}        = $variation;
  $self->{'_variation_id'}    = $variation_id;
  $self->{'source'}           = $source;
  $self->{'validation_code'}  = $validation_code;
  $self->{'consequence_type'} = $consequence_type || ['INTERGENIC'];
 
  return $self;
}



sub new_fast {
  my $class = shift;
  my $hashref = shift;
  return bless $hashref, $class;
}


=head2 allele_string

  Arg [1]    : string $newval (optional)
               The new value to set the allele_string attribute to
  Example    : $allele_string = $obj->allele_string()
  Description: Getter/Setter for the allele_string attribute.
               The allele_string is a '/' demimited string representing the
               alleles associated with this features variation.
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut

sub allele_string{
  my $self = shift;
  return $self->{'allele_string'} = shift if(@_);
  return $self->{'allele_string'};
}



=head2 display_id

  Arg [1]    : none
  Example    : print $vf->display_id(), "\n";
  Description: Returns the 'display' identifier for this feature. For
               VariationFeatures this is simply the name of the variation
               it is associated with.
  Returntype : string
  Exceptions : none
  Caller     : webcode
  Status     : At Risk

=cut

sub display_id {
  my $self = shift;
  return $self->{'variation_name'} || '';
}



=head2 variation_name

  Arg [1]    : string $newval (optional)
               The new value to set the variation_name attribute to
  Example    : $variation_name = $obj->variation_name()
  Description: Getter/Setter for the variation_name attribute.  This is the
               name of the variation associated with this feature.
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut

sub variation_name{
  my $self = shift;
  return $self->{'variation_name'} = shift if(@_);
  return $self->{'variation_name'};
}



=head2 map_weight

  Arg [1]    : int $newval (optional) 
               The new value to set the map_weight attribute to
  Example    : $map_weight = $obj->map_weight()
  Description: Getter/Setter for the map_weight attribute. The map_weight
               is the number of times this features variation was mapped to
               the genome.
  Returntype : int
  Exceptions : none
  Caller     : general
  Status     : At Risk

=cut

sub map_weight{
  my $self = shift;
  return $self->{'map_weight'} = shift if(@_);
  return $self->{'map_weight'};
}


=head2 get_all_TranscriptVariations

  Example     : $vf->get_all_TranscriptVariations;
  Description : Getter a list with all the TranscriptVariations associated associated to the VariationFeature
  Returntype  : ref to list of Bio::EnsEMBL::Variation::TranscriptVariation objects
  Exceptions  : None
  Caller      : general
  Status      : At Risk

=cut

sub get_all_TranscriptVariations{
    my $self = shift;
	
    if(!defined($self->{'transcriptVariations'}) && $self->{'adaptor'})    {
	 
	  my $tva;
	  
	  if($self->{'adaptor'}->db()) {
		$tva = $self->{'adaptor'}->db()->get_TranscriptVariationAdaptor();
	  }
	  
	  elsif($self->{'adaptor'}) {
		$tva = Bio::EnsEMBL::Variation::DBSQL::TranscriptVariationAdaptor->new_fake($self->{'adaptor'}->{'species'});
	  }
	  
	  #lazy-load from database on demand
	  $tva->fetch_all_by_VariationFeatures([$self]);
	  $self->{'transcriptVariations'} ||= [];
	  
	  # now set the highest priority one
	  $self->{'consequence_type'} = $self->_highest_priority($self->{'transcriptVariations'});
    }
    return $self->{'transcriptVariations'};
}

=head2 get_nearest_Gene

  Example     : $vf->get_nearest_Gene($flanking_size);
  Description : Getter a Gene which is associated to or nearest to the VariationFeature
  Returntype  : a reference to a list of objects of Bio::EnsEMBL::Gene
  Exceptions  : None
  Caller      : general
  Status      : At Risk

=cut

sub get_nearest_Gene{

    my $self = shift;
    my $flanking_size = shift; #flanking size is optional
    $flanking_size ||= 0;
    my $sa = $self->{'adaptor'}->db()->dnadb->get_SliceAdaptor();
    my $slice = $sa->fetch_by_Feature($self,$flanking_size);
    my @genes = @{$slice->get_all_Genes};
    return \@genes if @genes; #$vf is on the gene

    if (! @genes) { #if $vf is not on the gene, increase flanking size
      warning("flanking_size $flanking_size is not big enough to overlap a gene, increase it by 1,000,000");
      $flanking_size += 1000000;
      $slice = $sa->fetch_by_Feature($self,$flanking_size);
      @genes = @{$slice->get_all_Genes};
    }
    if (@genes) {
      my %distances = ();
      foreach my $g (@genes) {
        if ($g->seq_region_start > $self->start) {
          $distances{$g->seq_region_start-$self->start}=$g;
        }
        else {
          $distances{$self->start-$g->seq_region_end}=$g;
        }
      }
      my @distances = sort {$a<=>$b} keys %distances;
      my $shortest_distance = $distances[0];
      if ($shortest_distance) {
        my $nearest_gene = $distances{$shortest_distance};
        return [$nearest_gene];
      }
    }
    else {
      throw("variation_feature with flanking_size $flanking_size is not overlap with a gene, try a bigger flanking_size");
    }
}

=head2 add_TranscriptVariation

   Arg [1]     : Bio::EnsEMBL::Variation::TranscriptVariation
   Example     : $vf->add_TranscriptVariation($tv);
   Description : Adds another Transcript variation to the variation feature object
   Exceptions  : thrown on bad argument
   Caller      : Bio::EnsEMBL::Variation::TranscriptVariationAdaptor
   Status     : At Risk

=cut

sub add_TranscriptVariation{
    my $self= shift;
    if (@_){
	if(!ref($_[0]) || !$_[0]->isa('Bio::EnsEMBL::Variation::TranscriptVariation')) {
	    throw("Bio::EnsEMBL::Variation::TranscriptVariation argument expected");
	}
	#a variation feature can have multiple transcript Variations
	push @{$self->{'transcriptVariations'}},shift;
    }
}


=head2 variation

  Arg [1]    : (optional) Bio::EnsEMBL::Variation::Variation $variation
  Example    : $v = $vf->variation();
  Description: Getter/Setter for the variation associated with this feature.
               If not set, and this VariationFeature has an associated adaptor
               an attempt will be made to lazy-load the variation from the
               database.
  Returntype : Bio::EnsEMBL::Variation::Variation
  Exceptions : throw on incorrect argument
  Caller     : general
  Status     : Stable

=cut

sub variation {
  my $self = shift;

  if(@_) {
    if(!ref($_[0]) || !$_[0]->isa('Bio::EnsEMBL::Variation::Variation')) {
      throw("Bio::EnsEMBL::Variation::Variation argument expected");
    }
    $self->{'variation'} = shift;
  }
  elsif(!defined($self->{'variation'}) && $self->{'adaptor'} &&
        defined($self->{'_variation_id'})) {
    # lazy-load from database on demand
    my $va = $self->{'adaptor'}->db()->get_VariationAdaptor();
    $self->{'variation'} = $va->fetch_by_dbID($self->{'_variation_id'});
  }

  return $self->{'variation'};
}


=head2 display_consequence

  Args       : none
  Example    : $display_consequence = $vf->display_consequence();
  Description: Getter for the consequence type to display,
               when more than one
  Returntype : string
  Exceptions : throw on incorrect argument
  Caller     : webteam
  Status     : At Risk

=cut

sub display_consequence{
    my $self = shift;
    my $gene = shift;
 
    my $highest_priority;
    if (!defined $gene){
	#get the value to display from the consequence_type attribute
	$highest_priority = 'INTERGENIC';
	foreach my $ct (@{$self->get_consequence_type}){
	    if ($CONSEQUENCE_TYPES{$ct} < $CONSEQUENCE_TYPES{$highest_priority}){
		$highest_priority = $ct;
	    }
	}
    }
    else{
	#first, get all the transcripts, if any
	my $transcript_variations = $self->get_all_TranscriptVariations();
	#if no transcripts, return INTERGENIC type
	if (!defined $transcript_variations){
	    return 'INTERGENIC';
	}
	if (!ref $gene || !$gene->isa("Bio::EnsEMBL::Gene")){
	    throw("$gene is not a Bio::EnsEMBL::Gene type!");
	}
	my $transcripts = $gene->get_all_Transcripts();
	my %transcripts_genes;
	my @new_transcripts;
	map {$transcripts_genes{$_->dbID()}++} @{$transcripts};
	foreach my $transcript_variation (@{$transcript_variations}){
	    if (exists $transcripts_genes{$transcript_variation->transcript->dbID()}){
		push @new_transcripts,$transcript_variation;
	    }
	}
	$highest_priority = $self->_highest_priority(\@new_transcripts);	
    }

    return $highest_priority;
}

=head2 add_consequence_type

    Arg [1]     : string $consequence_type
    Example     : $vf->add_consequence_type("UPSTREAM")
    Description : Setter for the consequence type of this VariationFeature
                  Allowed values are: 'ESSENTIAL_SPLICE_SITE','STOP_GAINED','STOP_LOST','FRAMESHIFT_CODING',
		  'NON_SYNONYMOUS_CODING','SPLICE_SITE','SYNONYMOUS_CODING','REGULATORY_REGION',
		  '5PRIME_UTR','3PRIME_UTR','INTRONIC','UPSTREAM','DOWNSTREAM','INTERGENIC'
    ReturnType  : string
    Exceptions  : none
    Caller      : general
    Status      : At Risk

=cut

sub add_consequence_type{
    my $self = shift;
    my $consequence_type = shift;

    if ($CONSEQUENCE_TYPES{$consequence_type}){
	push @{$self->{'consequence_type'}}, $consequence_type;
	return $self->{'consequence_type'};
    }
    warning("You are trying to set the consequence type to a non-allowed type. The allowed types are: ", keys %CONSEQUENCE_TYPES);
    return '';
}

=head2 get_consequence_type

   Arg[1]      : (optional) Bio::EnsEMBL::Gene $g
   Example     : if($vf->get_consequence_type eq 'INTRONIC'){do_something();}
   Description : Getter for the consequence type of this variation, which is the highest of the transcripts that has.
                 If an argument provided, gets the highest of the transcripts where the gene appears
                 Allowed values are:'ESSENTIAL_SPLICE_SITE','STOP_GAINED','STOP_LOST','FRAMESHIFT_CODING',
		  'NON_SYNONYMOUS_CODING','SPLICE_SITE','SYNONYMOUS_CODING','REGULATORY_REGION',
		  '5PRIME_UTR','3PRIME_UTR','INTRONIC','UPSTREAM','DOWNSTREAM','INTERGENIC'
   Returntype : ref to array of strings
   Exceptions : throw if provided argument not a gene
   Caller     : general
   Status     : At Risk

=cut

sub get_consequence_type {
  my $self = shift;
  my $gene = shift;
    
  if(!defined $gene){
    return $self->{'consequence_type'};
  } 
  else{
      my $highest_priority;
    #first, get all the transcripts, if any
      my $transcript_variations = $self->get_all_TranscriptVariations();
      #if no transcripts, return INTERGENIC type
      if (!defined $transcript_variations){
	  return ['INTERGENIC'];
      }
      if (!ref $gene || !$gene->isa("Bio::EnsEMBL::Gene")){
	  throw("$gene is not a Bio::EnsEMBL::Gene type!");
      }
      my $transcripts = $gene->get_all_Transcripts();
      my %transcripts_genes;
      my @new_transcripts;
      map {$transcripts_genes{$_->dbID()}++} @{$transcripts};
      foreach my $transcript_variation (@{$transcript_variations}){
	  if (exists $transcripts_genes{$transcript_variation->transcript->dbID()}){
	    push @new_transcripts,$transcript_variation;
	}
      }
      $highest_priority = $self->_highest_priority(\@new_transcripts);	
      return $highest_priority;
  }
}


=head2 add_splice_site

    Arg [1]     : string $splice_site
    Example     : $vf->add_splice_site('ESSENTIAL_SPLICE_SITE')
    Description : Setter for the splice site type of this VariationFeature
                  Allowed values are: 'ESSENTIAL_SPLICE_SITE', 'SPLICE_SITE'
    ReturnType  : string
    Exceptions  : none
    Caller      : general


sub add_splice_site{
    my $self = shift;
    my $splice_site = shift;

    return $self->{'splice_site'} = $splice_site if ($SPLICE_SITES{$splice_site});
    warning("You are trying to set the splice site to a non-allowed type. The allowed types are: ", keys %SPLICE_SITES);
    return '';
}

=head2 get_splice_site

   Arg[1]      : (optional) Bio::EnsEMBL::Gene $g
   Example     : if($vf->get_splice_site eq 'SPLICE_SITE'){do_something();}
   Description : Getter for the splice site of this variation, which is the highest of the transcripts that has.
                 If an argument provided, gets the highest of the transcripts where the gene appears
                 Allowed values are:'ESSENTIAL_SPLICE_SITES','SPLICE_SITE'
   Returntype : string
   Exceptions : throw if provided argument not a gene
   Caller     : general


sub get_splice_site{
  my $self = shift;
  my $gene = shift;
    
  if(!defined $gene){
    return $self->{'splice_site'};
  } 
  else{
      my $highest_priority;
      #first, get all the transcripts, if any
      my $transcript_variations = $self->get_all_TranscriptVariations();
      #if no transcripts, return INTERGENIC type
      if (!defined $transcript_variations){
	  return '';
      }
      if (!ref $gene || !$gene->isa("Bio::EnsEMBL::Gene")){
	  throw("$gene is not a Bio::EnsEMBL::Gene type!");
      }
      my $transcripts = $gene->get_all_Transcripts();
      my %transcripts_genes;
      my @new_transcripts;
      map {$transcripts_genes{$_->dbID()}++} @{$transcripts};
      foreach my $transcript_variation (@{$transcript_variations}){
	  if (exists $transcripts_genes{$transcript_variation->transcript->dbID()}){
	      push @new_transcripts,$transcript_variation;
	  }
      }
      #get the highest type in the splice site
      foreach my $tv (@new_transcripts){
	  if ((defined $tv->splice_site) and ($SPLICE_SITES{$tv->splice_site} < $SPLICE_SITES{$highest_priority})){
	      $highest_priority = $tv->splice_site;
	  }
      }      
      return $highest_priority;      
  }
}

=head2 add_regulatory_region

    Arg [1]     : string $regulatory_region
    Example     : $vf->add_regulatory_region('REGULATORY_REGION')
    Description : Setter for the regulatory region type of this VariationFeature
                  Allowed value is: 'REGULATORY_REGION'
    ReturnType  : string
    Exceptions  : none
    Caller      : general


sub add_regulatory_region{
    my $self = shift;
    my $regulatory_region = shift;

    return $self->{'regulatory_region'} = $regulatory_region if ($REGULATORY_REGION{$regulatory_region});
    warning("You are trying to set the regulatory_region to a non-allowed type. The allowed type is: ", keys %REGULATORY_REGION);
    return '';
}

=head2 get_regulatory_region

   Arg[1]      : (optional) Bio::EnsEMBL::Gene $g
   Example     : if($vf->get_regulatory_region eq 'REGULATORY_REGION'){do_something();}
   Description : Getter for the regulatory region of this variation
                 If an argument provided, gets the highest of the transcripts where the gene appears
                 Allowed value is :'REGULATORY_REGION'
   Returntype : string
   Exceptions : throw if provided argument is not a gene
   Caller     : general


sub get_regulatory_region{
  my $self = shift;
  my $gene = shift;
    
  if(!defined $gene){
    return $self->{'regulatory_region'};
  } 
  else{
      my $regulatory_region;
      #first, get all the transcripts, if any
      my $transcript_variations = $self->get_all_TranscriptVariations();
      #if no transcripts, return INTERGENIC type
      if (!defined $transcript_variations){
	  return '';
      }
      if (!ref $gene || !$gene->isa("Bio::EnsEMBL::Gene")){
	  throw("$gene is not a Bio::EnsEMBL::Gene type!");
      }
      my $transcripts = $gene->get_all_Transcripts();
      my %transcripts_genes;
      my @new_transcripts;
      map {$transcripts_genes{$_->dbID()}++} @{$transcripts};
      foreach my $transcript_variation (@{$transcript_variations}){
	  if (exists $transcripts_genes{$transcript_variation->transcript->dbID()}){
	      push @new_transcripts,$transcript_variation;
	  }
      }

      foreach my $tv (@new_transcripts){
	if (defined $tv->regulatory_region ()){
	  $regulatory_region = $tv->regulatory_region();
	  last;
	}
      }
      return $regulatory_region;
  }
}

=cut

#for a list of transcript variations, gets the one with highest priority
sub _highest_priority{
    my $self= shift;
    my $transcript_variations = shift;
    my $highest_type = 'INTERGENIC';
    my $highest_splice = '';
    my $highest_regulatory = '';
    my @highest_priority;
    my %splice_site = ( 'ESSENTIAL_SPLICE_SITE' => 1,
			'SPLICE_SITE'           => 2);
    my %regulatory_region = ( 'REGULATORY_REGION' => 1);

    foreach my $tv (@{$transcript_variations}){
 	#with a frameshift coding, return, is the highest value
	my $consequences = $tv->consequence_type; #returns a ref to array
	foreach my $consequence_type (@{$consequences}){
	    if (defined $splice_site{$consequence_type}){
		if ((!defined $splice_site{$highest_splice}) || (defined $splice_site{$highest_splice} && $splice_site{$consequence_type} < $splice_site{$highest_splice})){
		    $highest_splice = $consequence_type;
		}
	    }
	    else{
		if (defined $regulatory_region{$consequence_type}){
		    if ((!defined $regulatory_region{$highest_regulatory}) || (defined $regulatory_region{$highest_regulatory} && $regulatory_region{$consequence_type} < $regulatory_region{$highest_regulatory})){
			$highest_regulatory = $consequence_type;
		    }
		}
		else{
		    if (defined $CONSEQUENCE_TYPES{$consequence_type} && $CONSEQUENCE_TYPES{$consequence_type} < $CONSEQUENCE_TYPES{$highest_type}){
			$highest_type = $consequence_type;
		    }
		}
	    }
	    
	}
	
    }   
    return ['INTERGENIC'] if (!defined $transcript_variations);
    push @highest_priority, $highest_regulatory if ($highest_regulatory ne '');
    push @highest_priority, $highest_splice if ($highest_splice ne '');
    push @highest_priority, $highest_type;
    
    return \@highest_priority;
}

=head2 ambig_code

    Args         : None
    Example      : my $ambiguity_code = $vf->ambig_code()
    Description  : Returns the ambigutiy code for the alleles in the VariationFeature
    ReturnType   : String $ambiguity_code
    Exceptions   : none    
    Caller       : General
    Status       : At Risk

=cut 

sub ambig_code{
    my $self = shift;
    
    return &ambiguity_code($self->allele_string());
}

=head2 var_class

    Args         : None
    Example      : my $variation_class = $vf->var_class()
    Description  : returns the class for the variation, according to dbSNP classification
    ReturnType   : String $variation_class
    Exceptions   : none
    Caller       : General
    Status       : At Risk

=cut

sub var_class{
    my $self = shift;
    return &variation_class($self->allele_string());
}


=head2 get_all_validation_states

  Arg [1]    : none
  Example    : my @vstates = @{$vf->get_all_validation_states()};
  Description: Retrieves all validation states for this variationFeature.  Current
               possible validation statuses are 'cluster','freq','submitter',
               'doublehit', 'hapmap'
  Returntype : reference to list of strings
  Exceptions : none
  Caller     : general
  Status     : At Risk

=cut

sub get_all_validation_states {
  my $self = shift;

  my @VSTATES = @Bio::EnsEMBL::Variation::Variation::VSTATES;

  my $code = $self->{'validation_code'};
  # convert the validation state strings into a bit field
  # this preserves the same order and representation as in the database
  # and filters out invalid states

  my %VSTATE2BIT = %Bio::EnsEMBL::Variation::Variation::VSTATE2BIT;
  my $vcode = 0;
  $code ||= [];
  foreach my $vstate (@$code) {
    $vcode |= $VSTATE2BIT{lc($vstate)} || 0;
  }

  # convert the bit field into an ordered array
  my @states;
  for(my $i = 0; $i < @VSTATES; $i++) {
    push @states, $VSTATES[$i] if((1 << $i) & $vcode);
  }
  return \@states;
}




=head2 add_validation_state

  Arg [1]    : string $state
  Example    : $vf->add_validation_state('cluster');
  Description: Adds a validation state to this variation.
  Returntype : none
  Exceptions : warning if validation state is not a recognised type
  Caller     : general
  Status     : At Risk

=cut

sub add_validation_state {
  my $self  = shift;
  my $state = shift;

  my %VSTATE2BIT = %Bio::EnsEMBL::Variation::Variation::VSTATE2BIT;
  my @VSTATES = @Bio::EnsEMBL::Variation::Variation::VSTATES;
  # convert string to bit value and add it to the existing bitfield
  my $bitval = $VSTATE2BIT{lc($state)};

  if(!$bitval) {
    warning("$state is not a recognised validation status. Recognised " .
            "validation states are: @VSTATES");
    return;
  }

  $self->{'validation_code'} |= $bitval;

  return;
}



=head2 source

  Arg [1]    : string $source (optional)
               The new value to set the source attribute to
  Example    : $source = $vf->source()
  Description: Getter/Setter for the source attribute
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : At Risk

=cut

sub source{
  my $self = shift;
  return $self->{'source'} = shift if(@_);
  return $self->{'source'};
}

=head2 is_tagged

  Args        : None
  Example     : my $populations = $vf->is_tagged();
  Description : If the variation is tagged in any population, returns an array with the populations where the variation_feature
                is tagged (using a criteria of r2 > 0.99). Otherwise, returns null
  ReturnType  : list of Bio::EnsEMBL::Variation::Population
  Exceptions  : none
  Caller      : general
  Status      : At Risk
  
=cut

sub is_tagged{
    my $self = shift;
    
    if ($self->{'adaptor'}){
	my $population_adaptor = $self->{'adaptor'}->db()->get_PopulationAdaptor();
	return $population_adaptor->fetch_tagged_Population($self);
    }
}

=head2 convert_to_SNP

  Args        : None
  Example     : my $snp = $vf->convert_to_SNP()
  Description : Creates a Bio::EnsEMBL::SNP object from Bio::EnsEMBL::VariationFeature. Mainly used for
                backwards comnpatibility
  ReturnType  : Bio::EnsEMBL::SNP
  Exceptions  : None
  Caller      : general      
  Status      : At Risk

=cut

sub convert_to_SNP{
    my $self = shift;

    require Bio::EnsEMBL::SNP;  #for backwards compatibility. It will only be loaded if the function is called

    my $snp = Bio::EnsEMBL::SNP->new_fast({
	        'dbID'       => $self->variation()->dbID(),
		'_gsf_start'  => $self->start,
		'_gsf_end'    => $self->end,
		'_snp_strand' => $self->strand,
		'_gsf_score'  => 1,
		'_type'       => $self->var_class,
		'_validated'  => $self->get_all_validation_states(),
		'alleles'    => $self->allele_string,
		'_ambiguity_code' => $self->ambig_code,
		'_mapweight'  => $self->map_weight,
		'_source' => $self->source
		});
    return $snp;
}

=head2 get_all_LD_values

    Args        : none
    Description : returns all LD values for this variation feature. This function will only work correctly if the variation
                  database has been attached to the core database. 
    ReturnType  : Bio::EnsEMBL::Variation::LDFeatureContainer
    Exceptions  : none
    Caller      : snpview
    Status      : At Risk
                : Variation database is under development.

=cut

sub get_all_LD_values{
    my $self = shift;
    
    if ($self->{'adaptor'}){
	my $ld_adaptor = $self->{'adaptor'}->db()->get_LDFeatureContainerAdaptor();
	return $ld_adaptor->fetch_by_VariationFeature($self);
    }
    return {};
}

=head2 get_all_sources

    Args        : none
    Example     : my @sources = @{$vf->get_all_sources()};
    Description : returns a list of all the sources for this
                  VariationFeature
    ReturnType  : reference to list of strings
    Exceptions  : none
    Caller      : general
    Status      : At Risk
                : Variation database is under development.
=cut

sub get_all_sources{
    my $self = shift;
   
    my @sources;
    my %sources;
    if ($self->{'adaptor'}){
	map {$sources{$_}++} @{$self->{'adaptor'}->get_all_synonym_sources($self)};
	$sources{$self->source}++;
	@sources = keys %sources;
	return \@sources;
    }
    return \@sources;
}

=head2 ref_allele_string

  Args       : none
  Example    : $reference_allele_string = $self->ref_allele_string()
  Description: Getter for the reference allele_string, always the first.
  Returntype : string
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut

sub ref_allele_string{
    my $self = shift;

    my @alleles = split /[\|\\\/]/,$self->allele_string;
    return $alleles[0];
}


=head2 get_all_VariationSets

    Args        : none
    Example     : my @vs = @{$vf->get_all_VariationSets()};
    Description : returns a reference to a list of all the VariationSets this
                  VariationFeature is a member of
    ReturnType  : reference to list of Bio::EnsEMBL::Variation::VariationSets
    Exceptions  : if no adaptor is attached to this object
    Caller      : general
    Status      : At Risk
=cut

sub get_all_VariationSets {
    my $self = shift;
    
    if (!$self->{'adaptor'}) {
      throw('An adaptor must be attached in order to get all variation sets');
    }
    my $vs_adaptor = $self->{'adaptor'}->db()->get_VariationSetAdaptor();
    my $variation_sets = $vs_adaptor->fetch_all_by_Variation($self->variation());
    
    return $variation_sets;
}


=head2 get_all_Alleles

  Args       : none
  Example    : @alleles = @{$vf->get_all_Alleles}
  Description: Gets all Allele objects from the underlying variation object,
			   with reference alleles first.
  Returntype : listref of Bio::EnsEMBL::Variation::Allele objects
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut

sub get_all_Alleles{
    my $self = shift;
	
	my @alleles = @{$self->variation->get_all_Alleles};
	
	# put all alleles in a hash
	my %order = ();
	foreach my $allele(@alleles) {
	  $order{$allele->allele} = 1;
	}
	
	$order{$self->ref_allele_string} = 2;
	
	# now sort them by population, submitter, allele
	my @new_alleles = sort {
	  ($a->population ? $a->population->name : "") cmp ($b->population ? $b->population->name : "") ||
	  ($a->subsnp ? $a->subsnp_handle : "") cmp ($b->subsnp ? $b->subsnp_handle : "") ||
	  $order{$b->allele} <=> $order{$a->allele}
	} @alleles;
	
	return \@new_alleles;
}


=head2 get_all_PopulationGenotypes

  Args       : none
  Example    : @pop_gens = @{$vf->get_all_PopulationGenotypes}
  Description: Gets all PopulationGenotype objects from the underlying variation
			   object, with reference genotypes first.
  Returntype : listref of Bio::EnsEMBL::Variation::PopulationGenotype objects
  Exceptions : none
  Caller     : general
  Status     : Stable

=cut

sub get_all_PopulationGenotypes{
    my $self = shift;
	
	my @gens = @{$self->variation->get_all_PopulationGenotypes};
	
	# put all alleles in a hash
	my %order = ();
	foreach my $gen(@gens) {
	  # homs low priority, hets higher
	  $order{$gen->allele1.$gen->allele2} = ($gen->allele1 eq $gen->allele2 ? 1 : 2);
	}
	
	# ref hom highest priority
	$order{$self->ref_allele_string x 2} = 3;
	
	# now sort them by population, submitter, genotype
	my @new_gens = sort {
	  ($a->population ? $a->population->name : "") cmp ($b->population ? $b->population->name : "") ||
	  ($a->subsnp ? $a->subsnp_handle : "") cmp ($b->subsnp ? $b->subsnp_handle : "") ||
	  $order{$b->allele1.$b->allele2} <=> $order{$a->allele1.$a->allele2}
	} @gens;
	
	return \@new_gens;
}

=head2 get_all_hgvs_notations

  Arg [1]    : Bio::EnsEMBL::Feature $ref_feature (optional)
               Get the HGVS notation of this VariationFeature relative to the slice it is on. If an optional reference feature is supplied, returns the coordinates
	       relative to this feature.
  Arg [2]    : string (Optional)
	       Indicate whether the HGVS notation should be reported in genomic coordinates or cDNA coordinates.
	       'g' -> Genomic position numbering
	       'c' -> cDNA position numbering
  Arg [3]    : string (Optional)
               A name to use for the reference can be supplied. By default the name returned by the display_id() method of the reference feature will be used. 
  Example    : print $vf->get_all_hgvs_notations();
  Description: Returns a string array with the HGVS notation for each allele of this VariationFeature. By default uses the
               slice it is plcaed on as reference but a different reference feature can be supplied.
  Returntype : String array
  Exceptions : Throws exception if VariationFeature can not be described relative to the feature_Slice of the supplied reference feature
  Caller     : general
  Status     : Experimental

=cut

sub get_all_hgvs_notations {
    my $self = shift;
    my $ref_feature = shift;
    my $numbering = shift;
    my $reference_name = shift;
    
    # If no reference feature is supplied, set it to the slice underlying this VariationFeature
    $ref_feature ||= $self->slice();
    #�By default, use genomic position numbering
    $numbering ||= 'g';
    #�Use the feature's display id as reference name unless specified otherwise
    $reference_name ||= $ref_feature->display_id();
    
    # Check that the numbering scheme is compatible with the type of reference supplied
    return ("HGVS $numbering notation is not available for $ref_feature") if ($ref_feature->isa('Bio::EnsEMBL::Slice') && $numbering !~ m/[g]/); 
    return ("HGVS $numbering notation is not available for $ref_feature") if ($ref_feature->isa('Bio::EnsEMBL::Transcript') && $numbering !~ m/[gcp]/); 
    return ("HGVS $numbering notation is not available for $ref_feature") if ($ref_feature->isa('Bio::EnsEMBL::Gene') && $numbering !~ m/[g]/); 
      
    # Check that HGVS notation is implemented for the supplied feature type
    return ["HGVS notation has not been implemented for $ref_feature"] unless ($ref_feature->isa('Bio::EnsEMBL::Slice') || $ref_feature->isa('Bio::EnsEMBL::Transcript') || $ref_feature->isa('Bio::EnsEMBL::Gene'));
    
    #�If the reference feature is a slice, set the ref_slice to the feature, otherwise to the feature_Slice
    my $ref_slice;
    if ($ref_feature->isa('Bio::EnsEMBL::Slice')) {
      $ref_slice = $ref_feature;
    }
    else {
      $ref_slice = $ref_feature->feature_Slice;
    }
    
    # Transfer this VariationFeature onto the slice of the reference feature
    my $tr_vf = $self->transfer($ref_slice);
    
    # Return undef if this VariationFeature could not be transferred
    return [] if (!defined($tr_vf));
    
    #�Return undef if this VariationFeature does not fall within the supplied feature
    return [] if ($tr_vf->start < 1 || $tr_vf->end > ($ref_feature->end - $ref_feature->start + 1));
    
    # The variation should always be reported on the positive strand. So change the orientation of the feature if necessary. Use a flag to indicate this
    my $revcomp = 0;
    if ($tr_vf->strand() < 0) {
      $revcomp = 1;
      $tr_vf->strand(1);
    }
    
    # Get the underlying slice
    $ref_slice = $tr_vf->slice();
    
    #�Coordinates to use in the notation
    my $display_start = $tr_vf->start();
    my $display_end = $tr_vf->end();
    
    # Get all alleles for this VariationFeature and create a HGVS notation for each.
    # Store them in a hash with the allele as keys to avoid duplicates
    # First, get the notation in genomic coordinate numbering for all
    my %hgvs;
    foreach my $allele (split(/\//,$tr_vf->allele_string())) {
      
      # Skip if the allele contains weird characters
      next if $allele =~ m/[^ACGT\-]/ig;
      
      # If the VariationFeature is on the opposite strand, relative to what is stored in database, flip the allele
      if ($revcomp) {
	reverse_comp(\$allele);
      }
      
      # Skip if we've already seen this allele
      next if (exists($hgvs{$allele}));
      
      # Call method in Utils::Sequence but we don't need to pass more reference sequence than the variation and an equal number of nucleotides upstream (for duplication checking)
      my $t_allele = $allele;
      $t_allele =~ s/\-//g;
      my $ref_start = length($t_allele) + 1;
      my $ref_end = length($t_allele) + ($tr_vf->end() - $tr_vf->start()) + 1;
      my $seq_start = ($tr_vf->start() - $ref_start);
      # Should we be at the beginning of the sequence, adjust the coordinates to not cause an exception
      if ($seq_start < 0) {
	$ref_start += $seq_start;
	$ref_end += $seq_start;
	$seq_start = 0;
      }
      my $ref_seq = substr($ref_slice->seq(),$seq_start,$ref_end);
      my $hgvs_notation = hgvs_variant_notation($allele,$ref_seq,$ref_start,$ref_end,$display_start,$display_end);
      
      # Skip if e.g. allele is identical to the reference slice
      next if (!defined($hgvs_notation));
      
      # Add the name of the reference
      $hgvs_notation->{'name'} = $reference_name;
      # Add the position_numbering scheme
      $hgvs_notation->{'numbering'} = $numbering;
      
      # If the feature is a transcript and we want to get cDNA coordinates, need to convert the "slice" coordinates to exon+intron coordinates
      if ($ref_feature->isa('Bio::EnsEMBL::Transcript') && $numbering =~ m/[c]/) {
	
	# If this transcript is non-coding, the numbering should not include 'c' and the position should start from the start of the transcript
	if (!defined($ref_feature->cdna_coding_start())) {
	  $hgvs_notation->{'numbering'} = '';
	}
	
	# Expects coordinates in the forward orientation, relative to the chromosome but still having positions relative to the transcript slice start and end
	# Get these by subtracting the variation position from the transcript end in case the transcript is on the reverse strand
	# In case it is on the forward strand, add the transcript start coordinate, since the TranscriptMapper works on the transcript->slice but the
	#�variation coordinates refer to transcript->feature_Slice
	my $recalc_start = ($ref_feature->strand > 0 ? ($hgvs_notation->{'start'} + $ref_feature->start - 1) : ($ref_feature->end - $hgvs_notation->{'end'} + 1));
	my $recalc_end = ($ref_feature->strand > 0 ? ($hgvs_notation->{'end'} + $ref_feature->start - 1) : ($ref_feature->end - $hgvs_notation->{'start'} + 1));
	
	my $vf_start = _get_cDNA_position($recalc_start,$ref_feature);
	my $vf_end = _get_cDNA_position($recalc_end,$ref_feature);
	
	# Make sure that start is always less than end
	my ($exon_start_coord,$intron_start_offset) = $vf_start =~ m/([0-9]+)\+?(\-?[0-9]+)?/;
	my ($exon_end_coord,$intron_end_offset) = $vf_end =~ m/([0-9]+)\+?(\-?[0-9]+)?/;
	$intron_start_offset ||= 0;
	$intron_end_offset ||= 0;
	($vf_start,$vf_end) = ($vf_end,$vf_start) if (($exon_start_coord + $intron_start_offset) > ($exon_end_coord + $intron_end_offset));
	
	# Update the notation
	$hgvs_notation->{'start'} = $vf_start;
	$hgvs_notation->{'end'} = $vf_end;
      }
      
      # Construct the HGVS notation from the data in the hash 
      $hgvs_notation->{'hgvs'} = $hgvs_notation->{'name'} . ':' . (length($hgvs_notation->{'numbering'}) > 0 ? $hgvs_notation->{'numbering'} . '.' : '') . $hgvs_notation->{'start'} . ($hgvs_notation->{'end'} ne $hgvs_notation->{'start'} ? '_' . $hgvs_notation->{'end'} : '');
      if ($hgvs_notation->{'type'} eq '>') {
	$hgvs_notation->{'hgvs'} .= $hgvs_notation->{'ref'} . $hgvs_notation->{'type'} . $hgvs_notation->{'alt'};
      }
      elsif ($hgvs_notation->{'type'} eq 'delins') {
	$hgvs_notation->{'hgvs'} .= 'del' . $hgvs_notation->{'ref'} . 'ins' . $hgvs_notation->{'alt'};
      }
      elsif ($hgvs_notation->{'type'} eq 'ins') {
	$hgvs_notation->{'hgvs'} .= $hgvs_notation->{'type'} . $hgvs_notation->{'alt'};
      }
      else {
	$hgvs_notation->{'hgvs'} .= $hgvs_notation->{'type'} . $hgvs_notation->{'ref'};
      }
      
      $hgvs{$allele} = $hgvs_notation;
    
    }
    
    #�Push the HGVS strings into an array and return it
    my @strings;
    foreach my $allele (keys %hgvs) {
      push(@strings,$hgvs{$allele}->{'hgvs'});
    }
    return \@strings;
}

#�Convert a position on a transcript (in the forward orientation and relative to the start position of the slice the transcript is on) to a cDNA coordinate
#�If the position is in an intron, the boundary position of the closest exon and a + or - offset into the intron is returned.
# If the position is 5' of the start codon, it is reported relative to the start codon (-1 being the last nucleotide before the 'A' of ATG).
#�If the position is 3' pf the stop codon, it is reported with a '*' prefix and the offset from the start codon (*1 being the first nucleotide after the last position of the stop codon)
sub _get_cDNA_position {
  my $position = shift;
  my $transcript = shift;
  
  my $cdna_position = $position;
  
  # Get all exons and sort them in positional order
  my @exons = sort {$a->start() <=> $b->start()} @{$transcript->get_all_Exons()};
  my $n_exons = scalar(@exons);
  my $strand = $transcript->strand();
  
  # Loop over the exons and get the coordinates of the variation in exon+intron notation
  for (my $i=0; $i<$n_exons; $i++) {
    
    # Skip if the start point is beyond this exon
    next if ($position > $exons[$i]->end());
    
    # If the start coordinate is within this exon
    if ($position >= $exons[$i]->start()) {
      #�Get the cDNA start coordinate of the exon and add the number of nucleotides from the exon boundary to the variation
      # If the transcript is in the opposite direction, count from the end instead
      $cdna_position = $exons[$i]->cdna_start($transcript) + ($strand > 0 ? ($position - $exons[$i]->start) : ($exons[$i]->end() - $position));
      last;
    }
    # Else the start coordinate is between this exon and the previous one, determine which one is closest and get coordinates relative to that one
    else {
      my $updist = ($position - $exons[$i-1]->end());
      my $downdist = ($exons[$i]->start() - $position);
      
      # If the distance to the upstream exon is the shortest, or equal and in the positive orientation, use that
      if ($updist < $downdist || ($updist == $downdist && $strand >= 0)) {
        # If the orientation is reversed, we should use the cDNA start and a '-' offset
        $cdna_position = ($strand >= 0 ? $exons[$i-1]->cdna_end($transcript) . '+' : $exons[$i-1]->cdna_start($transcript) . '-') . $updist;
      }
      # Else if downstream is shortest...
      else {
        # If the orientation is reversed, we should use the cDNA end and a '+' offset
        $cdna_position = ($strand >= 0 ? $exons[$i]->cdna_start($transcript) . '-' : $exons[$i]->cdna_end($transcript) . '+') . $downdist;
      }
      last;
    }
  }
  
  # Shift the position to make it relative to the start codon
  my $start_codon = $transcript->cdna_coding_start();
  my $stop_codon = $transcript->cdna_coding_end();
  
  # Disassemble the cDNA coordinate into the exon and intron parts
  my ($cdna_coord,$intron_offset) = $cdna_position =~ m/([0-9]+)([\+\-][0-9]+)?/;
  
  #�Start by correcting for the stop codon
  if (defined($stop_codon) && $cdna_coord > $stop_codon) {
    #�Get the offset from the stop codon
    $cdna_coord -= $stop_codon;
    # Prepend a * to indicate the position is in the 3' UTR
    $cdna_coord = '*' . $cdna_coord;
  }
  elsif (defined($start_codon)) {
    # If the position is beyond the start codon, add 1 to get the correct offset
    $cdna_coord += ($cdna_coord >= $start_codon);
    #�Subtract the position of the start codon
    $cdna_coord -= $start_codon;
  }
  
  # Re-assemble the cDNA position
  $cdna_position = $cdna_coord . (defined($intron_offset) ? $intron_offset : '');
  
  return $cdna_position;
}
1;
