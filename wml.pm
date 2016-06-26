use strict;
use warnings;

###Takes a string of WML and tokenizes it
sub tokenize {
  my $wmldocument = shift;
  my @tokens;

  my @characters = split(//,$wmldocument);
  my ($tag_open, $attribute_open, $quotes_open) = (0,0,0);
  my $tag_name;
  my $attribute_name;
  my $value;
  while(my $character = shift @characters) {
    if (($character eq '[') && !($tag_open) && !($attribute_open) && !($quotes_open)) {
      $tag_open = 1;
    }
    elsif (($character eq ']') && ($tag_open) && !($attribute_open) && !($quotes_open)) {
      $tag_open = 0;
      push(@tokens,"[$tag_name]");
      $tag_name = '';
    }
    elsif ($character =~ /[a-zA-Z0-9\/_-]/) {
      if (!($tag_open) && !($attribute_open) && !($quotes_open)) {
        $attribute_open = 1;
      }
      $tag_name .= $character if ($tag_open);
      $attribute_name .= $character if ($attribute_open);
      $value .= $character if ($quotes_open);
    }
    elsif (($character eq '=') && !($tag_open) && ($attribute_open) && !($quotes_open)) {
      $attribute_open = 0;
    }
    elsif ($character eq '"') {
      if ($quotes_open) {
        my $next_character = shift @characters;
        if (defined $next_character && $next_character eq '"') {
          $value .= $character;
          $value .= $next_character;
        }
        else {
          $quotes_open = 0;
          push(@tokens,"$attribute_name=\"$value\"");
          $attribute_name = '';
          $value = '';
        }
      }
      else {
        $quotes_open = 1;
      }
    }
    elsif (($character =~ /(\s|.)/) && !($tag_open) && !($attribute_open) && ($quotes_open)) {
      $value .= $character;
    }
  }
  return @tokens;
}

###Takes an array of WML tokens and recursively builds it into a tree
###Each layer of the tree is a hash containing:
###name - the name of the layer
###attr - attributes of that layer
###chldn - child tags of that layer
sub populate_layer {
  my ($current_tag, @tokens) = @_;

  my $new_layer = {};
  $new_layer->{'name'} = $current_tag;
  $new_layer->{'attr'} = {};
  $new_layer->{'chldn'} = [];

  print "\nStarting on layer $current_tag\n";

  while(my $token = shift @tokens) {
    print "Current token is $token\n";
    if($token =~ /^\[([a-zA-Z0-9-_]+)]$/) {
      my $tag = $1;
      print "$tag is a child of $current_tag\n";
      #$new_layer->{'chldn'}->{$tag} = populate_layer($tag);
      my $new_child;
      ($new_child, @tokens) = populate_layer($tag, @tokens);
      push(@{$new_layer->{'chldn'}},$new_child);
    }
    elsif ($token =~ /^([a-zA-Z0-9-_]+)=\"((.|\r|\n|\s)*)\"$/) {
      print "$1 is an attribute of $current_tag and has value $2\n";
      $new_layer->{'attr'}->{$1} = $2;
    }
    elsif ($token =~ /^\[\/$current_tag]$/) {
      print "Finished layer $current_tag\n";
      return $new_layer;
    }
    elsif ($token =~ /^\[\/([a-zA-Z0-9-_])]$/) {
      print "Found invalid closing tag: $token\n";
    }
    else {
      print "Found uknown token type: $token\n";
    }
    print "back to $current_tag\n";
  }
  return $new_layer;
}

###Returns the first matching child from a tree
sub get_firstborn {
  my ($tree, $wanted) = @_;

  foreach my $current_child (@{$tree->{'chldn'}}) {
    if ($current_child->{'name'} eq $wanted) {
      return $current_child;
    }
  }
  return 0;
}

###Returns an array of matching children from a tree
sub get_children {
  my ($tree, $wanted) = @_;
  my @children;
  foreach my $current_child (@{$tree->{'chldn'}}) {
    if ($current_child->{'name'} eq $wanted) {
      push(@children,$current_child);
    }
  }
  if (@children) {
    return @children;
  }
  else {
    return 0;
  }
}

sub run_test {
  open (my $file, "/media/dhoagland/STORAGE/dhoagland/source/grillobot/wmlexample");
  my $string = join("", <$file>);
  close $file;
  my @base_tokens = tokenize($string);
  #foreach my $token (@base_tokens) { print "$token\n\n"; }
  my $tree = populate_layer('data',@base_tokens);
}

1;