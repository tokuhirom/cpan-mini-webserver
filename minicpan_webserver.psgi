#!perl
use strict;
use warnings;
use lib 'lib';
use CPAN::Mini::Webserver;
use Plack::Loader;
use CGI::Emulate::PSGI;
use Plack::Request;
use Plack::Middleware::ContentLength;
use Plack::Builder;
use Data::Dumper;

$|++;

print "BEFORE SETUP\n";
my $server = CPAN::Mini::Webserver->new();
$server->setup();
print "AFTER SETUP\n";

$Data::Dumper::Maxdepth = 1;

builder {
    enable "ContentLength";

    sub {
        my $req = Plack::Request->new(shift);
        $server->handle_request($req);
    };
};

__END__

=head1 NAME

minicpan_webserver - Search and browse Mini CPAN

=head1 SYNOPSIS

  % minicpan_webserver
  % minicpan_webserver --port 8090

=head1 DESCRIPTION

This program provides a web server that allows you to search and
browse Mini CPAN. First you must install CPAN::Mini and create a local
copy of CPAN using minicpan.  Then you may run minicpan_webserver and
search and browse Mini CPAN at http://localhost:2963/. The listening
port can be configured with C<--port> command line option.

=head1 MINICPAN CONFIGURATION

CPAN::Mini::Webserver can optionally return the real names of authors
instead of an ascii representation of them. This depends on the file
'authors/00whois.xml' being mirrored from CPAN. CPAN::Mini doesn't do
this by default. You can tell it to mirror this file by putting the
following line in your .minicpanrc:

  also_mirror: authors/00whois.xml

=head1 AUTHOR

Leon Brocard <acme@astray.com>

=head1 COPYRIGHT

Copyright (C) 2008, Leon Brocard.

This module is free software; you can redistribute it or 
modify it under the same terms as Perl itself.
