package CPAN::Mini::Webserver;
use App::Cache;
use Archive::Peek;
use CPAN::Mini::App;
use CPAN::Mini::Webserver::Index;
use CPAN::Mini::Webserver::Templates;
use CPAN::Mini::Webserver::Templates::CSS;
use CPAN::Mini::Webserver::Templates::Images;
use Encode;
use File::Spec::Functions qw(canonpath);
use File::Type;
use List::MoreUtils qw(uniq);
use Module::InstalledVersion;
use Mouse;
use Parse::CPAN::Authors;
use Parse::CPAN::Packages;
use Parse::CPAN::Whois;
use Parse::CPAN::Meta;
use Pod::Simple::HTML;
use Path::Class;
use PPI;
use PPI::HTML;
use Template::Declare;
use Log::Minimal;
use HTTP::Date ();

our $REQUEST;

Template::Declare->init(
    roots => [
        'CPAN::Mini::Webserver::Templates',
        'CPAN::Mini::Webserver::Templates::CSS',
        'CPAN::Mini::Webserver::Templates::Images',
    ]
);

has 'directory'           => ( is => 'rw', isa => 'Path::Class::Dir' );
has 'scratch'             => ( is => 'rw', isa => 'Path::Class::Dir' );
has 'author_type'         => ( is => 'rw' );
has 'parse_cpan_authors'  => ( is => 'rw' );
has 'parse_cpan_packages' => ( is => 'rw', isa => 'Parse::CPAN::Packages' );
has 'pauseid'             => ( is => 'rw' );
has 'distvname'           => ( is => 'rw' );
has 'filename'            => ( is => 'rw' );
has 'index' => ( is => 'rw', isa => 'CPAN::Mini::Webserver::Index' );

our $VERSION = '0.45';

sub get_file_from_tarball {
    my ( $self, $distribution, $filename ) = @_;

    my $file
        = file( $self->directory, 'authors', 'id', $distribution->prefix );
    my $peek = Archive::Peek->new( filename => $file );
    my $contents = $peek->file($filename);
    return $contents;
}

sub checksum_data_for_author {
    my ( $self, $pauseid ) = @_;

    my $file = file(
        $self->directory, 'authors', 'id',
        substr( $pauseid, 0, 1 ),
        substr( $pauseid, 0, 2 ),
        $pauseid, 'CHECKSUMS',
    );

    return unless -f $file;

    my ( $content, $checksum );
    {
        local $/;
        open my $fh, "$file" or die "$file: $!";
        $content = <$fh>;
        close $fh;
    }

    eval $content;

    return $checksum;
}

sub setup {
    my $self      = shift;
    infof("start setup");

    my %config    = CPAN::Mini->read_config;
    my $directory = dir( glob $config{local} );
    $self->directory($directory);
    my $authors_filename = file( $directory, 'authors', '01mailrc.txt.gz' );
    my $packages_filename
        = file( $directory, 'modules', '02packages.details.txt.gz' );
    die "Please set up minicpan"
        unless defined($directory)
            && ( -d $directory )
            && ( -f $authors_filename )
            && ( -f $packages_filename );
    my $cache = App::Cache->new( { ttl => 60 * 60 } );

    my $whois_filename = file( $directory, 'authors', '00whois.xml' );
    my $parse_cpan_authors;
    if ( -f $whois_filename ) {
        infof("do parse_cpan_whois");
        $self->author_type('Whois');
        $parse_cpan_authors = $cache->get_code( 'parse_cpan_whois',
            sub { Parse::CPAN::Whois->new( $whois_filename->stringify ) } );
    } else {
        infof("do parse_cpan_authors");
        $self->author_type('Authors');
        $parse_cpan_authors = $cache->get_code( 'parse_cpan_authors',
            sub { Parse::CPAN::Authors->new( $authors_filename->stringify ) }
        );
    }
    infof("do parse_cpan_packages");
    my $parse_cpan_packages = $cache->get_code( 'parse_cpan_packages',
        sub { Parse::CPAN::Packages->new( $packages_filename->stringify ) } );

    $self->parse_cpan_authors($parse_cpan_authors);
    $self->parse_cpan_packages($parse_cpan_packages);

    my $scratch = dir( $cache->scratch );
    $self->scratch($scratch);

    infof("do create index");
    my $index = $cache->get_code( 'index',
        sub {
            my $x = CPAN::Mini::Webserver::Index->new;
            $x->create_index( $parse_cpan_authors, $parse_cpan_packages );
            $x;
        }
    );
    $self->index($index);

    infof("finished setup");
}

sub handle_request {
    my ( $self, $req ) = @_;

    local $REQUEST = $req;

    my $path = $req->path_info();
    debugf("access to $path");

    # $raw, $download and $install should become $action?
    my ($raw,       $install,  $download, $pauseid,
        $distvname, $filename, $prefix
    );
    if ( $path =~ m{^/~} ) {
        ( undef, $pauseid, $distvname, $filename ) = split( '/', $path, 4 );
        $pauseid =~ s{^~}{};
    } elsif ( $path =~ m{^/(raw|download|install)/~} ) {
        ( undef, undef, $pauseid, $distvname, $filename )
            = split( '/', $path, 5 );

        (     $1 eq 'raw'     ? $raw
            : $1 eq 'install' ? $install
            : $download
        ) = 1;
        $pauseid =~ s{^~}{};
    } elsif ( $path =~ m{^/((?:modules|authors)/.+$)} ) {
        $prefix = $1;
    }
    $self->pauseid($pauseid);
    $self->distvname($distvname);
    $self->filename($filename);

    # warn "$path / $raw / $download / $pauseid / $distvname / $filename";

    if ( $path eq '/' ) {
        $self->index_page($req);
    } elsif ( $path eq '/search/' ) {
        $self->search_page($req);
    } elsif ( $raw && $pauseid && $distvname && $filename ) {
        $self->raw_page($req);
    } elsif ( $install && $pauseid && $distvname && $filename ) {
        $self->install_page($req);
    } elsif ( $download && $pauseid && $distvname ) {
        $self->download_file($req);
    } elsif ( $pauseid && $distvname && $filename ) {
        $self->file_page($req);
    } elsif ( $pauseid && $distvname ) {
        $self->distribution_page($req);
    } elsif ($pauseid) {
        $self->author_page($req);
    } elsif ( $path =~ m{^/perldoc} ) {
        $self->pod_page($req);
    } elsif ( $path =~ m{^/dist/} ) {
        $self->dist_page($req);
    } elsif ( $path =~ m{^/package/} ) {
        $self->package_page($req);
    } elsif ($prefix) {
        $self->download_cpan($prefix);
    } elsif ( $path eq '/static/css/screen.css' ) {
        $self->direct_to_template( "css_screen", "text/css" );
    } elsif ( $path eq '/static/css/print.css' ) {
        $self->direct_to_template( "css_print", "text/css" );
    } elsif ( $path eq '/static/css/ie.css' ) {
        $self->direct_to_template( "css_ie", "text/css" );
    } elsif ( $path eq '/static/images/logo.png' ) {
        $self->direct_to_template( "images_logo", "image/png" );
    } elsif ( $path eq '/static/images/favicon.png' ) {
        $self->direct_to_template( "images_favicon", "image/png" );
    } elsif ( $path eq '/favicon.ico' ) {
        $self->direct_to_template( "images_favicon", "image/png" );
    } elsif ( $path eq '/static/xml/opensearch.xml' ) {
        $self->direct_to_template( "opensearch",
            "application/opensearchdescription+xml",
        );
    } else {
        my ($q) = $path =~ m'/(.*?)/?$';
        $self->not_found_page($q);
    }

}

sub render_td {
    my ($self, $tmpl, $params) = @_;
    debugf("rendering '$tmpl'");
    my $html = Template::Declare->show(
        $tmpl => $params
    );
    return [200, ['Content-Type' => 'text/html; charset=utf-8'], [$html]];
}

sub index_page {
    my $self = shift;

    my $recent_filename = file( $self->directory, 'RECENT' );
    my @recent;
    if ( -f $recent_filename ) {
        my $fh = IO::File->new($recent_filename) || die $!;
        while ( my $line = <$fh> ) {
            chomp $line;
            next unless $line =~ m{authors/id/};

            my $d = CPAN::DistnameInfo->new($line);

            push @recent, $d;
        }
    }
    return $self->render_td(
        'index',
        {   recents            => \@recent,
            parse_cpan_authors => $self->parse_cpan_authors,
        }
    );
}

sub not_found_page {
    my $self = shift;
    my $q    = shift;
    my ( $authors, $dists, $packages ) = $self->_do_search($q);
    my $html = Template::Declare->show(
        '404',
        {   parse_cpan_authors => $self->parse_cpan_authors,
            q                  => $q,
            authors            => $authors,
            distributions      => $dists,
            packages           => $packages
        }
    );
    [404, ['Content-Type' => 'text/html; charset=utf-8'], [$html]];
}

sub redirect {
    my ($self, $location) = @_;

    my $url = do {
        if ( $location =~ m{^https?://} ) {
            $location;
        }
        else {
            my $url = $REQUEST->base;
            $url      =~ s{/+$}{};
            $location =~ s{^/+([^/])}{/$1};
            $url .= $location;
        }
    };
    debugf("redirect to $url");
    return [302, ['Location' => $url], []];
}

sub search_page {
    my ($self, $req) = @_;
    my $q    = $req->param('q');
    Encode::_utf8_on($q);    # we know that we have sent utf-8

    my ( $authors, $dists, $packages ) = $self->_do_search($q);
    return $self->render_td(
        'search',
        {   parse_cpan_authors => $self->parse_cpan_authors,
            q                  => $q,
            authors            => $authors,
            distributions      => $dists,
            packages           => $packages
        }
    );
}

sub _do_search {
    my $self    = shift;
    my $q       = shift;
    my $index   = $self->index;
    my @results = $index->search($q);
    my $au_type = $self->author_type;
    my ( @authors, @distributions, @packages );

    if ( $q !~ /\w(?:::|-)\w/ ) {
        @authors = uniq grep { ref($_) eq "Parse::CPAN::${au_type}::Author" }
            @results;
    }
    if ( $q !~ /\w::\w/ ) {
        @distributions
            = uniq grep { ref($_) eq 'Parse::CPAN::Packages::Distribution' }
            @results;
    }
    if ( $q !~ /\w-\w/ ) {
        @packages = uniq grep { ref($_) eq 'Parse::CPAN::Packages::Package' }
            @results;
    }

    @authors = sort { $a->name cmp $b->name } @authors;

    @distributions = sort {
        my @acount = $a->dist =~ /-/g;
        my @bcount = $b->dist =~ /-/g;
        scalar(@acount) <=> scalar(@bcount)
            || $a->dist cmp $b->dist
    } @distributions;

    @packages = sort {
        my @acount = $a->package =~ /::/g;
        my @bcount = $b->package =~ /::/g;
        scalar(@acount) <=> scalar(@bcount)
            || $a->package cmp $b->package
    } @packages;

    return ( \@authors, \@distributions, \@packages );

}

sub author_page {
    my $self    = shift;
    my $pauseid = $self->pauseid;

    my @distributions = sort { $a->distvname cmp $b->distvname }
        grep { $_->cpanid eq uc $pauseid }
        $self->parse_cpan_packages->distributions;
    my $author = $self->parse_cpan_authors->author( uc $pauseid );

    my $checksum = $self->checksum_data_for_author( uc $pauseid );
    my %dates;
    if ( not $@ and defined $checksum ) {
        foreach my $dist (@distributions) {
            $dates{ $dist->distvname }
                = $checksum->{ $dist->filename }->{mtime};
        }
    }

    return $self->render_td(
        'author',
        {   author        => $author,
            pauseid       => $pauseid,
            distributions => \@distributions,
            dates         => \%dates,
        }
    );
}

sub distribution_page {
    my $self      = shift;
    my $pauseid   = $self->pauseid;
    my $distvname = $self->distvname;

    my ($distribution)
        = grep { $_->cpanid eq uc $pauseid && $_->distvname eq $distvname }
        $self->parse_cpan_packages->distributions;

    my $filename = $distribution->distvname . "/META.yml";
    my $metastr  = $self->get_file_from_tarball( $distribution, $filename );
    my $meta     = {};
    my @yaml     = eval { Parse::CPAN::Meta::Load($metastr); };
    if ( not $@ ) {
        $meta = $yaml[0];
    }

    my $checksum_data = $self->checksum_data_for_author( uc $pauseid );
    $meta->{'release date'}
        = $checksum_data->{ $distribution->filename }->{mtime};

    my @filenames = $self->list_files($distribution);

    return $self->render_td(
        'distribution',
        {   author       => $self->parse_cpan_authors->author( uc $pauseid ),
            distribution => $distribution,
            pauseid      => $pauseid,
            distvname    => $distvname,
            filenames    => \@filenames,
            meta         => $meta,
            pcp          => $self->parse_cpan_packages,
        }
    );
}

sub pod_page {
    my ($self, $req) = @_;
    my ($pkgname) = $req->env->{QUERY_STRING};

    my $m = $self->parse_cpan_packages->package($pkgname);
    my $d = $m->distribution;

    my ( $pauseid, $distvname ) = ( $d->cpanid, $d->distvname );
    my $url = "/package/$pauseid/$distvname/$pkgname/";

    return $self->redirect($url);
}

sub install_page {
    my $self      = shift;
    my $pauseid   = $self->pauseid;
    my $distvname = $self->distvname;

    my ($distribution)
        = grep { $_->cpanid eq uc $pauseid && $_->distvname eq $distvname }
        $self->parse_cpan_packages->distributions;

    my $file
        = file( $self->directory, 'authors', 'id', $distribution->prefix );

    die "NOT IMPLEMENTED YET";

    $self->send_http_header(200);
    printf '<html><body><h1>Installing %s</h1><pre>',
        $distribution->distvname;

    warn sprintf "Installing '%s'\n", $distribution->prefix;

    require CPAN;    # loads CPAN::Shell
    CPAN::Shell->install( $distribution->prefix );

    printf '</pre><a href="/~%s/%s">Go back</a></body></html>',
        $self->pauseid, $self->distvname;
}

sub file_page {
    my $self      = shift;
    my $pauseid   = $self->pauseid;
    my $distvname = $self->distvname;
    my $filename  = $self->filename;

    my ($distribution)
        = grep { $_->cpanid eq uc $pauseid && $_->distvname eq $distvname }
        $self->parse_cpan_packages->distributions;

    my $contents = $self->get_file_from_tarball( $distribution, $filename );

    my $parser = Pod::Simple::HTML->new;
    $parser->perldoc_url_prefix($REQUEST->base() . "/perldoc?");
    $parser->index(0);
    $parser->no_whining(1);
    $parser->no_errata_section(1);
    $parser->output_string( \my $html );
    $parser->parse_string_document($contents);
    $html =~ s/^.*<!-- start doc -->//s;
    $html =~ s/<!-- end doc -->.*$//s;

#   $html
#       =~ s/^(.*%3A%3A.*)$/my $x = $1; ($x =~ m{indexItem}) ? 1 : $x =~ s{%3A%3A}{\/}g; $x/gme;

    return $self->render_td(
        'file',
        {   author       => $self->parse_cpan_authors->author( uc $pauseid ),
            distribution => $distribution,
            pauseid      => $pauseid,
            distvname    => $distvname,
            filename     => $filename,
            contents     => $contents,
            html         => $html,
        }
    );
}

sub download_file {
    my $self      = shift;
    my $pauseid   = $self->pauseid;
    my $distvname = $self->distvname;
    my $filename  = $self->filename;

    my ($distribution)
        = grep { $_->cpanid eq uc $pauseid && $_->distvname eq $distvname }
        $self->parse_cpan_packages->distributions;
    my $prefix = file( '', 'authors', 'id', $distribution->prefix );
    my $file = file( $self->directory, $prefix );

    if ($filename) {
        my $contents
            = $self->get_file_from_tarball( $distribution, $filename );
        return [200,
            ['Content-Type' => 'text/plain'],
            [$contents]];
    } else {
        return $self->redirect($prefix);
    }
}

sub raw_page {
    my ($self, $req) = @_;
    debugf("show raw_page");
    my $pauseid   = $self->pauseid;
    my $distvname = $self->distvname;
    my $filename  = $self->filename;

    my ($distribution)
        = grep { $_->cpanid eq uc $pauseid && $_->distvname eq $distvname }
        $self->parse_cpan_packages->distributions;

    my $file
        = file( $self->directory, 'authors', 'id', $distribution->prefix );

    my $contents = $self->get_file_from_tarball( $distribution, $filename );

    my $html;

    if ( $filename =~ /\.(pm|pl|PL|t)$/ ) {
        my $document  = PPI::Document->new( \$contents );
        my $highlight = PPI::HTML->new( line_numbers => 0 );
        my $pretty    = $highlight->html($document);

        my $split = '<span class="line_number">';

        # turn significant whitespace into &nbsp;
        my @lines = map {
            $_ =~ s{</span>( +)}{"</span>" . ("&nbsp;" x length($1))}e;
            "$split$_";
        } split /$split/, $pretty;

        # remove the extra line number tag
        @lines = map { s{<span class="line_number">}{}; $_ } @lines;

        # remove newlines
        $_ =~ s{<br>}{}g foreach @lines;

        # link module names to ourselves
        my $port = $req->uri->port;
        my $host = $req->uri->host;
        @lines = map {
            $_
                =~ s{<span class="word">([^<]+?::[^<]+?)</span>}{<span class="word"><a href="http://$host:$port/perldoc?$1">$1</a></span>};
            $_;
        } @lines;
        $html = join '', @lines;
    }

    return $self->render_td(
        'raw',
        {   author       => $self->parse_cpan_authors->author( uc $pauseid ),
            distribution => $distribution,
            filename     => $filename,
            pauseid      => $pauseid,
            distvname    => $distvname,
            contents     => $contents,
            html         => $html,
        }
    );
}

sub dist_page {
    my ($self, $req) = @_;
    my ($dist) = $req->path_info =~ m{^/dist/(.+?)$};
    my $latest = $self->parse_cpan_packages->latest_distribution($dist);
    if ($latest) {
        return $self->redirect( "/~" . $latest->cpanid . "/" . $latest->distvname );
    } else {
        $self->not_found_page($dist);
    }
}

sub package_page {
    my ($self, $req) = @_;
    my $path = $req->path_info();
    my ( $pauseid, $distvname, $package )
        = $path =~ m{^/package/(.+?)/(.+?)/(.+?)/$};

    my ($p) = grep {
               $_->package                 eq $package
            && $_->distribution->distvname eq $distvname
            && $_->distribution->cpanid    eq uc($pauseid)
    } $self->parse_cpan_packages->packages;
    my $distribution = $p->distribution;
    my @filenames    = $self->list_files($distribution);
    my $postfix      = $package;
    $postfix =~ s{^.+::}{}g;
    $postfix .= '.pm';
    my ($filename) = grep { $_ =~ /$postfix$/ }
        sort { length($a) <=> length($b) } @filenames;
    my $url  = "/~$pauseid/$distvname/$filename";

    return $self->redirect($url);
}

sub download_cpan {
    my ( $self, $prefix ) = @_;
    my $file_type = File::Type->new;
    my $file      = file( $self->directory,
        canonpath( URI::Escape::uri_unescape($prefix) ) );

    open my $fh, $file or return $self->not_found_page($prefix);

    my $content_type = $file_type->checktype_filename($file);
    $content_type = 'text/plain' unless $file->basename =~ /\./;

    return [
        200,
        [
            'Content-Type'        => $content_type,
            'Content-Disposition' => "attachment; filename=" . $file->basename,
            'Content-Length'      => -s $fh
        ],
        $fh
    ];
}

sub list_files {
    my ( $self, $distribution ) = @_;
    my $file
        = file( $self->directory, 'authors', 'id', $distribution->prefix );
    my $peek = Archive::Peek->new( filename => $file );
    my @filenames = $peek->files;
    return @filenames;
}

sub direct_to_template {
    my $self     = shift;
    my $template = shift;
    my $mime     = shift;

    return [
        200,
        [
            Expires => HTTP::Date::time2str( time() + 24 * 60 * 60 ),
            ( $mime ? ( 'Content-Type' => $mime ) : () )
        ],
        [Template::Declare->show($template)]
    ];
}

1;

__END__

=head1 NAME

CPAN::Mini::Webserver - Search and browse Mini CPAN

=head1 SYNOPSIS

  % minicpan_webserver
  
=head1 DESCRIPTION

This module is the driver that provides a web server that allows
you to search and browse Mini CPAN. First you must install
CPAN::Mini and create a local copy of CPAN using minicpan.
Then you may run minicpan_webserver and search and 
browse Mini CPAN at http://localhost:2963/.

You may access the Subversion repository at:

  http://code.google.com/p/cpan-mini-webserver/

And may join the mailing list at:

  http://groups.google.com/group/cpan-mini-webserver

=head1 AUTHOR

Leon Brocard <acme@astray.com>

=head1 COPYRIGHT

Copyright (C) 2008, Leon Brocard.

=head1 LICENSE

This module is free software; you can redistribute it or 
modify it under the same terms as Perl itself.
