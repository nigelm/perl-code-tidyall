package Code::TidyAll::Plugin::CSSUnminifier;

use strict;
use warnings;

use IPC::System::Simple qw(run);
use Text::ParseWords qw(shellwords);

use Moo;

extends 'Code::TidyAll::Plugin';

our $VERSION = '0.64';

sub _build_cmd {'cssunminifier'}

sub transform_file {
    my ( $self, $file ) = @_;

    run( $self->cmd, shellwords( $self->argv ), $file, $file );
}

1;

# ABSTACT: Use cssunminifier with tidyall

__END__

=pod

=head1 SYNOPSIS

   In configuration:

   [CSSUnminifier]
   select = static/**/*.css
   argv = -w=2

=head1 DESCRIPTION

Runs L<cssunminifier|https://npmjs.org/package/cssunminifier>, a simple CSS
tidier.

=head1 INSTALLATION

Install L<npm|https://npmjs.org/>, then run

    npm install cssunminifier -g

=head1 CONFIGURATION

=over

=item argv

Arguments to pass to C<cssunminifier>

=item cmd

Full path to C<cssunminifier>

=back
