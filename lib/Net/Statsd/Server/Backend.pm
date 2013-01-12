# ABSTRACT: Backend base class for Net::Statsd::Server

package Net::Statsd::Server::Backend;

use strict;
use warnings;

sub new {
  my ($class, $startup_time, $config) = @_;

  my $name = name($class);
  $class = ref $class || $class;

  my $self = {
    lastFlush => $startup_time,
    lastException => $startup_time,
    config => $config->{$name},
  };

  bless $self, $class;

  # Subclass way of doing special things
  $self->init();

  return $self;
}

sub config {
  $_[0]->{config};
}

sub name {
  my ($self) = @_;

  my $backend_name = ref($self) || $self;
  $backend_name =~ s{ :: ([^:]+) $}{$1}x;
  $backend_name = lc $backend_name;

  return $backend_name;
}

sub flush {
  die "Base class. Implement your own flush()";
}

sub status {
  die "Base class. Implement your own status()";
}

1;
