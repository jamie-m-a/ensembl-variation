use strict;
use warnings;

# Package for outputting progress information

package Progress;

# Creates a new Progress object
sub new {
    my $p;
    $p->{'checkpoints'} = [];
    $p->{'n'} = 0;
    
    bless $p,'Progress';
    return $p;
}

# Set a new checkpoint with an optional label
sub checkpoint {
    my $self = shift;
    my $label = shift;
    
    $self->{'n'}++;
    $label ||= $self->{'n'};
    
    my $time = time();
    my ($pack,$file,$line) = caller();
    
    my $cp = {
        'label' => $label,
        'time' => $time,
        'package' => $pack,
        'file' => $file,
        'line' => $line
    };
    
    push(@{$self->{'checkpoints'}},$cp);
}

#�Get the time between two checkpoints. If only the first is specified, gets the time from that checkpoint to the current time. If none is specified, gets the time from the last checkpoint up until now
sub duration {
    my $self = shift;
    my $start_checkpoint = shift;
    my $end_checkpoint = shift;
    
    # Create a local checkpoint for the current time if none was specified
    if (!defined($end_checkpoint)) {
        my ($pack,$file,$line) = caller();
        $end_checkpoint = {
            'label' => 'current location',
            'time' => time(),
            'package' => $pack,
            'file' => $file,
            'line' => $line
        };
    }
    # Else, locate the desired checkpoint
    else {
        my $gotit = 0;
        foreach my $cp (@{$self->{'checkpoints'}}) {
            next if ($cp->{'label'} ne $end_checkpoint);
            $end_checkpoint = $cp;
            $gotit++;
            last;
        }
        # Check that the checkpoint was actually found, otherwise return a string saying it couldn't be found
        return "The checkpoint '$end_checkpoint' could not be found!\n" unless ($gotit);
    }
    # If no starting checkpoint was specified, use the last one
    $start_checkpoint = $self->{'checkpoints'}[$self->{'n'}-1]{'label'} unless (defined($start_checkpoint));
    
    # Locate the desired checkpoint
    my $gotit = 0;
    foreach my $cp (@{$self->{'checkpoints'}}) {
        next if ($cp->{'label'} ne $start_checkpoint);
        $start_checkpoint = $cp;
        $gotit++;
        last;
    }
    # Check that the checkpoint was actually found, otherwise return a string saying it couldn't be found
    return "The checkpoint '$start_checkpoint' could not be found!\n" unless ($gotit);
    
    # Swap the checkpoints if necessary to make sure end is always after start
    ($end_checkpoint,$start_checkpoint) = ($start_checkpoint,$end_checkpoint) if ($start_checkpoint->{'time'} > $end_checkpoint->{'time'});
    
    # Get the duration in seconds
    my $duration = $end_checkpoint->{'time'} - $start_checkpoint->{'time'};
    
    # Convert the duration into other time units
    my $format = time_format($duration);
    
    # Construct the string
    my $str = "";
    foreach my $unit (('weeks','days','hours','minutes','seconds')) {
        $str .= $format->{$unit} . " $unit, ";
    }
    $str .= " spent between checkpoints\n";
    foreach my $cp (($start_checkpoint,$end_checkpoint)) {
        $str .= "\t" . $cp->{'label'};
        $str .= " [" . $cp->{'package'};
        $str .= "::" . $cp->{'file'};
        $str .= ", line " . $cp->{'line'} . "]\n";
    }
    return $str;
}

sub location {
    my ($pack,$file,$line) = caller();
    my $str = localtime() . "\t\tAt " . $pack . "::" . $file . ", line $line\n";
    return $str;
}


sub time_format {
    my $time = shift;
    
    my $minute = 60;
    my $hour = 60*$minute;
    my $day = 24*$hour;
    my $week = 7*$day;
    
    my $weeks = int($time/$week);
    $time -= $weeks*$week;
    
    my $days = int($time/$day);
    $time -= $days*$day;
    
    my $hours = int($time/$hour);
    $time -= $hours*$hour;
    
    my $minutes = int($time/$minute);
    $time -= $minutes*$minute;
    
    my $seconds = $time;
    
    my %formatted = (
        'weeks' => $weeks,
        'days' => $days,
        'hours' => $hours,
        'minutes' => $minutes,
        'seconds' => $seconds
    );
    
    return \%formatted;
}

#�Pretty-print the checkpoints or a specific checkpoint
sub to_string {
    my $self = shift;
    my $label = shift;
    
    my $str = "";
    foreach my $cp (@{$self->{'checkpoints'}}) {
        next if (defined($label) && $label ne $cp->{'label'});
        
        $str .= localtime($cp->{'time'}) . "\t\tCheckpoint " . $cp->{'label'} . ": At " . $cp->{'package'} . "::" . $cp->{'file'} . ", line $cp->{'line'}\n";
    }
    
    return $str;
}

1;