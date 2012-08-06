package Code::TidyAll::SVN::Precommit;
use Capture::Tiny qw(capture_stdout capture_stderr);
use Code::TidyAll;
use Code::TidyAll::Util qw(dirname mkpath realpath tempdir_simple write_file);
use Log::Any qw($log);
use Moo;
use SVN::Look;
use Try::Tiny;

# Public
has 'conf_file'        => ( is => 'ro', default => sub { "tidyall.ini" } );
has 'extra_conf_files' => ( is => 'ro', default => sub { [] } );
has 'reject_on_error'  => ( is => 'ro' );
has 'repos'            => ( is => 'ro', default => sub { $ARGV[0] } );
has 'tidyall_class'    => ( is => 'ro', default => sub { 'Code::TidyAll' } );
has 'tidyall_options'  => ( is => 'ro', default => sub { {} } );
has 'txn'              => ( is => 'ro', default => sub { $ARGV[1] } );

# Private
has 'cat_file_cache' => ( init_arg => undef, is => 'ro', default => sub { {} } );
has 'revlook'        => ( init_arg => undef, is => 'lazy' );

sub _build_revlook {
    my $self = shift;
    return SVN::Look->new( $self->repos, '-t' => $self->txn );
}

sub check {
    my ( $class, %params ) = @_;

    my $fail_msg;

    try {
        my $self = $class->new(%params);

        my @files = ( $self->revlook->added(), $self->revlook->updated() );
        $log->info("----------------------------");
        $log->infof(
            "%s [%s] repos = %s; txn = %s",
            scalar(localtime), $$, scalar( getpwuid($<) ),
            $self->repos, $self->txn
        );
        $log->infof( "looking at files: %s", join( ", ", @files ) );

        my %root_files;
        foreach my $file (@files) {
            if ( my $root = $self->find_root_for_file($file) ) {
                my $rel_file = substr( $file, length($root) + 1 );
                $root_files{$root}->{$rel_file}++;
            }
            else {
                my $msg =
                  sprintf( "** could not find '%s' upwards from '%s'", $self->conf_file, $file );
                $log->error($msg);
                die $msg if $self->reject_on_error;
            }
        }

        my @results;
        while ( my ( $root, $file_map ) = each(%root_files) ) {
            my $tempdir = tempdir_simple();
            my @files   = keys(%$file_map);
            foreach my $rel_file ( $self->conf_file, @{ $self->extra_conf_files }, @files ) {

                # TODO: what if cat fails
                my $contents  = $self->cat_file("$root/$rel_file");
                my $full_path = "$tempdir/$rel_file";
                mkpath( dirname($full_path), 0, 0775 );
                write_file( $full_path, $contents );
            }
            my $tidyall = $self->tidyall_class->new_from_conf_file(
                join( "/", $tempdir, $self->conf_file ),
                no_cache   => 1,
                check_only => 1,
                mode       => 'commit',
                %{ $self->tidyall_options },
            );
            my $stdout = capture_stdout {
                push( @results, $tidyall->process_files( map { "$tempdir/$_" } @files ) );
            };
            if ($stdout) {
                chomp($stdout);
                $log->info($stdout);
            }
        }

        if ( my @error_results = grep { $_->error } @results ) {
            my $error_count = scalar(@error_results);
            $fail_msg = join(
                "\n",
                sprintf(
                    "%d file%s did not pass tidyall check",
                    $error_count, $error_count > 1 ? "s" : ""
                ),
                map { join( ": ", $_->path, $_->msg ) } @error_results
            );
        }
    }
    catch {
        my $error = $_;
        $log->error($error);
        die $error if $params{reject_on_error};
    };
    die $fail_msg if $fail_msg;
}

sub find_root_for_file {
    my ( $self, $file ) = @_;

    my $conf_file  = $self->conf_file;
    my $search_dir = dirname($file);
    $search_dir =~ s{/+$}{};
    my $cnt = 0;
    while (1) {
        if ( $self->cat_file("$search_dir/$conf_file") ) {
            return $search_dir;
        }
        elsif ( $search_dir eq '/' || $search_dir eq '' || $search_dir eq '.' ) {
            return undef;
        }
        else {
            $search_dir = dirname($search_dir);
        }
        die "inf loop!" if ++$cnt > 100;
    }
}

sub cat_file {
    my ( $self, $file ) = @_;
    my $contents;
    if ( exists( $self->cat_file_cache->{$file} ) ) {
        $contents = $self->cat_file_cache->{$file};
    }
    else {
        try {
            capture_stderr { $contents = $self->revlook->cat($file) };
        }
        catch {
            $contents = '';
        };
        $self->cat_file_cache->{$file} = $contents;
    }
    return $contents;
}

1;

__END__

=pod

=head1 NAME

Code::TidyAll::SVN::Precommit - Subversion precommit hook that requires files
to be tidyall'd

=head1 SYNOPSIS

  In hooks/pre-commit in your svn repo:

    #!/usr/bin/perl
    use Code::TidyAll::SVN::Precommit;
    use Log::Any::Adapter (File => "/path/to/hooks/logs/tidyall.log");
    use strict;
    use warnings;
    
    Code::TidyAll::SVN::Precommit->check();

=head1 DESCRIPTION

This module implements a L<Subversion pre-commit
hook|http://svnbook.red-bean.com/en/1.7/svn.ref.reposhooks.pre-commit.html>
that checks if all files are tidied and valid according to L<tidyall|tidyall>,
and rejects the commit if not.

=head1 METHODS

=over

=item check (key/value params...)

Class method. Check that all files being added or modified in this commit are
tidied and valid according to L<tidyall|tidyall>. If not, then the entire
commit is rejected and the reason(s) are output to the client. e.g.

    % svn commit -m "fixups" CHI.pm CHI/Driver.pm 
    Sending        CHI/Driver.pm
    Sending        CHI.pm
    Transmitting file data ..svn: Commit failed (details follow):
    svn: Commit blocked by pre-commit hook (exit code 255) with output:
    2 files did not pass tidyall check
    lib/CHI.pm: *** 'PerlTidy': needs tidying
    lib/CHI/Driver.pm: *** 'PerlCritic': Code before strictures are enabled
      at /tmp/Code-TidyAll-0e6K/Driver.pm line 2
      [TestingAndDebugging::RequireUseStrict]

The configuration file (C<tidyall.ini> by default) must be checked into svn.
For each file, the hook will look upwards from the file's repo location and use
the first configuration file it finds.

By default, if C<tidyall.ini> cannot be found, or if a runtime error occurs, a
warning is logged (see L</LOGGING> below) but the commit is allowed to proceed.
This is so that unexpected problems do not prevent a team from committing code.

Passes mode = "commit" by default; see L<modes|tidyall/MODES>.

Key/value parameters:

=over

=item conf_file

Name of configuration file, defaults to C<tidyall.ini>

=item extra_conf_files

A listref of configuration files referred to from C<tidyall.ini>, e.g.

    extra_conf_files => ['perlcriticrc', 'perltidyrc']

=item reject_on_error

If C<tidyall.ini> cannot be found for some/all the files, or if a runtime error
occurs, reject the commit.

=item repos

Repository path being committed; defaults to C<< $ARGV[0] >>

=item tidyall_class

Subclass to use instead of L<Code::TidyAll|Code::TidyAll>

=item tidyall_options

Options to pass to the L<Code::TidyAll|Code::TidyAll> constructor

=item txn

Commit transaction; defaults to C<< $ARGV[1] >>

=back

=back

=head1 LOGGING

This module uses L<Log::Any|Log::Any> to log its activity, including all files
that were checked, an inability to find C<tidyall.ini>, and any runtime errors
that occur. You can create a simple datestamped log file with

    use Log::Any::Adapter (File => "/path/to/hooks/logs/tidyall.log");

or do something fancier with one of the other L<Log::Any
adapters|Log::Any::Adapter>.

Having a log file is especially useful with precommit hooks since there is no
way for the hook to send back output on a successful commit.

=cut