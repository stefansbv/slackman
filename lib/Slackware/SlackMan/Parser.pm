package Slackware::SlackMan::Parser;

use strict;
use warnings;

use 5.010;

no if ($] >= 5.018), 'warnings' => 'experimental';
use feature "switch";

our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS);

BEGIN {

  require Exporter;

  $VERSION     = 'v1.0.4';
  @ISA         = qw(Exporter);

  @EXPORT_OK   = qw{
    parse_packages
    parse_history
    parse_variables
    parse_manifest
    parse_changelog
    parse_module_name
  };

  %EXPORT_TAGS = (
    all => \@EXPORT_OK,
  );

}

use Data::Dumper;
use IO::Uncompress::Bunzip2 qw(bunzip2 $Bunzip2Error);
use File::Basename;

use Slackware::SlackMan::DB      qw(:all);
use Slackware::SlackMan::Config  qw(:all);
use Slackware::SlackMan::Utils   qw(:all);
use Slackware::SlackMan::Package qw(:all);
use Slackware::SlackMan::Repo    qw(:all);


sub parse_changelog {

  my ($repo, $callback_status) = @_;

  my $repository          = $repo->{'id'};
  my $changelog_separator = quotemeta('+--------------------------+');

  unless(download_repository_metadata($repository, 'changelog', \&$callback_status)) {
    &$callback_status('skip') if ($callback_status);
    return(0);
  }

  my $changelog_file = sprintf("%s/%s/ChangeLog.txt", $slackman_conf->{directory}->{'cache'}, $repository);
  return(0) unless (-e $changelog_file);

  my $changelog_contents = file_read($changelog_file);
  return(0) unless($changelog_contents);

  $dbh->do('DELETE FROM changelogs WHERE repository = ?', undef, $repository);

  chomp($changelog_contents);

  my @changelogs = split(/$changelog_separator/, $changelog_contents);
  my @columns    = qw(timestamp package status name version arch build tag repository security_fix category description);
  my @values     = ();

  &$callback_status('parse') if ($callback_status);

  my $num = 0;

  foreach my $changelog (@changelogs) {

    callback_spinner($num);
    $num++;

    chomp($changelog);

    my @lines               = split(/\n/, trim($changelog));
    my $changelog_time      = changelog_date_to_time($lines[0]);
    my $changelog_timestamp = time_to_timestamp($changelog_time);

    @lines     = @lines[ 1 .. $#lines ];
    $changelog = join("\n", @lines);
    $changelog =~ s/(\n^  )/|/gm;

    my @changelog_lines = split(/\n/, $changelog);

    foreach my $line (@changelog_lines) {

      my ($package, $status, $name, $version, $arch, $tag, $build, $description, $security_fix, $text, $category);

      $security_fix = 0;

      # Standard Slackware Changelog format (directory/package.ext:  status. description)
      if ($line =~ /^([[:graph:]]+):\s+(.*)/gm) {

        $package = $1;
        $text    = $2;

        ($status, $description) = ($text =~ m/(added|rebuilt|removed|upgraded|updated|patched|renamed|moved|name change|switched).(.*)/gi) if ($text);

        $security_fix = 1 if ($description && $description =~ /Security fix/);

        $description =~ s/\|/\n/g  if ($description);
        $description =~ s/^  //gm  if ($description);

        my $package_info = package_info(basename($package));

        $name    = $package_info->{'name'};
        $version = $package_info->{'version'};
        $arch    = $package_info->{'arch'};
        $build   = $package_info->{'build'};
        $tag     = $package_info->{'tag'};

      } else {

        next unless ($line =~ /(added|rebuilt|removed|upgraded|updated|patched|renamed|moved|name change|switched)/i);

        # AlienBob ChangeLog
        if ($line =~ /([[:graph:]]+):\s+(updated to|upgraded to|added|added a|rebuilt|patched)\s+((v\s|v)([[:graph:]]+))/i) {

          $package = $1;
          $status  = $2;
          $version = $3;

        # AlienBob Changelog
        } elsif ($line =~ /([[:graph:]]+):\s+(updated to|upgraded to|added|added a|rebuilt|patched)\s+([[:graph:]]+)/i) {

          $package = $1;
          $status  = $2;
          $version = $3;

        # AlienBob Changelog
        } elsif ($line =~ /([[:graph:]]+) added version (\d.([[:graph:]]+))/i) {

          $package = $1;
          $version = $2;
          $status  = 'added';

        # AlienBob Changelog
        } elsif ($line =~ /([[:graph:]]+) updated for version (\d.([[:graph:]]+))/i) {

          $package = $1;
          $version = $2;
          $status  = 'upgraded';

        # slackonly ChangeLog
        } elsif ($line =~ /(([[:graph:]]+)\/([[:graph:]]+))\s(added|removed|rebuilt|updated|upgraded)*/i) {

          $package = $1;
          $status  = $4;

        }

        $version =~ s/(\.|\;|\,)$// if ($version);
        $package =~ s/\://          if ($package);

        $status  = 'upgraded' if ($status && $status =~ /(updated|upgraded)/i);
        $status  = 'added'    if ($status && $status =~ /added/i);

      }

      next     if (defined($version) && $version !~ /\d/);
      next unless ($status);

      $category = dirname($package) || '';

      my @row = (
        $changelog_timestamp,    # timestamp
        $package,                # package
        lc($status),             # status
        $name,                   # name
        $version,                # version
        $arch,                   # arch
        $build,                  # build
        $tag,                    # tag
        $repository,             # repository
        $security_fix,           # security fix
        $category,               # category
        trim($description),      # description
      );

      push(@values, \@row);

    }


#     foreach my $line (@lines) {
# 
#       chomp($line);
# 
#       next if ($line =~ /^\s/);
#       next if ($line =~ /\*\:/);
#       next if ($line =~ /\.img/);
# 
#       next unless ($line =~ /(added|rebuilt|removed|upgraded|updated|patched|renamed|moved|name change|switched)/i);
# 
#       my ($package, $status, $name, $version, $arch, $tag, $build);
# 
#       # Standard Slackware ChangeLog format (directory/package.ext: status)
#       if ($line =~ /([[:graph:]]+t?z):\s+(Added|Rebuilt|Removed|Upgraded|Updated|Patched|Renamed|Moved|Name Change|Switched)/i) {
# 
#         $package = $1;
#         $status  = $2;
# 
#       # AlienBob Changelog
#       } elsif ($line =~ /([[:graph:]]+):\s+(updated to|upgraded to|added|added a|rebuilt|patched)\s+((v\s|v)([[:graph:]]+))/i) {
# 
#         $package = $1;
#         $status  = $2;
#         $version = $3;
# 
#       # AlienBob Changelog
#       } elsif ($line =~ /([[:graph:]]+):\s+(updated to|upgraded to|added|added a|rebuilt|patched)\s+([[:graph:]]+)/i) {
# 
#         $package = $1;
#         $status  = $2;
#         $version = $3;
# 
#       # AlienBob Changelog
#       } elsif ($line =~ /([[:graph:]]+) added version (\d.([[:graph:]]+))/i) {
# 
#         $package = $1;
#         $version = $2;
#         $status  = 'added';
# 
#       # AlienBob Changelog
#       } elsif ($line =~ /([[:graph:]]+) updated for version (\d.([[:graph:]]+))/i) {
# 
#         $package = $1;
#         $version = $2;
#         $status  = 'upgraded';
# 
#       # slackonly ChangeLog
#       } elsif ($line =~ /(([[:graph:]]+)\/([[:graph:]]+))\s(added|removed|rebuilt|updated|upgraded)*/i) {
# 
#         $package = $1;
#         $status  = $4;
# 
#       }
# 
#       next     if (defined($version) && ! $version =~ /\d/);
#       next unless ($status);
# 
#       $version =~ s/(\.|\;|\,)$// if ($version);
#       $package =~ s/\://          if ($package);
# 
#       $status  = 'upgraded' if ($status && $status =~ /(updated|upgraded)/i);
#       $status  = 'added'    if ($status && $status =~ /added/i);
# 
#       if ($package =~ /(txz|tgz|tbz|tlz)/) {
# 
#         my $package_info = package_info(basename($package));
# 
#         next unless ($package_info->{'name'});
#         next unless ($package_info->{'version'});
#         next unless ($package_info->{'build'} =~ /^[0-9]+$/);
# 
#         $name    = $package_info->{'name'};
#         $version = $package_info->{'version'};
#         $arch    = $package_info->{'arch'};
#         $build   = $package_info->{'build'};
#         $tag     = $package_info->{'tag'};
# 
#       } else {
#         $name = basename($package);
#       }
# 
#       my @row = (
#         $changelog_timestamp,    # timestamp
#         $package,                # package
#         lc($status),             # status
#         $name,                   # name
#         $version,                # version
#         $arch,                   # arch
#         $build,                  # build
#         $tag,                    # tag
#         $repository,             # repository
#         0
#       );
# 
#       push(@values, \@row);
# 
#     }

  }

  &$callback_status('save') if ($callback_status);

  db_bulk_insert(
    'table'   => 'changelogs',
    'columns' => \@columns,
    'values'  => \@values,
  );

  db_compact();

}


sub parse_checksums {

  my ($repo) = @_;

  unless(download_repository_metadata($repo->{'id'}, 'checksums')) {
    return(0);
  }

  my $checksums_file = sprintf("%s/%s/CHECKSUMS.md5", $slackman_conf->{directory}->{'cache'}, $repo->{'id'});
  return(0) unless (-e $checksums_file);

  my $checksums_contents = file_read($checksums_file);
  return(0) unless($checksums_contents);

  my @checksums = split(/\n/, $checksums_contents);
  my @filtered_checksums = ();

  foreach (@checksums) {
    next unless ($_ =~ /\.t(g|x|b|l)z$/);
    push(@filtered_checksums, $_);
  }

  return @filtered_checksums;

}


sub parse_packages {

  my ($repo, $callback_status) = @_;

  unless(download_repository_metadata($repo->{'id'}, 'packages', \&$callback_status, \&$callback_status)) {
    &$callback_status('skip') if ($callback_status);
    return(0);
  }

  my $repository = $repo->{'id'};
  my $mirror     = $repo->{'mirror'};

  my $packages_file = sprintf("%s/%s/PACKAGES.TXT", $slackman_conf->{directory}->{'cache'}, $repository);

  return(0) unless (-e $packages_file);

  my $packages_contents = file_read($packages_file);
  return(0) unless($packages_contents);

  &$callback_status('parse') if ($callback_status);

  my @packages  = split(/\n{2,}/, $packages_contents);
  my @checksums = parse_checksums($repo);

  my $last_update = shift(@packages);
     $last_update =~ s/PACKAGES.TXT;\s+// if ($last_update);

  $dbh->do('DELETE FROM packages WHERE repository = ?', undef, $repository);

  my @columns = qw(repository priority name package version build tag arch
                   category summary description mirror location required
                   conflicts suggests size_compressed size_uncompressed checksum);
  my @values  = ();

  my $num = 0;

  foreach my $metadata (@packages) {

    my $data = package_metadata($metadata);

    callback_spinner($num);
    $num++;

    next unless ($data->{'name'});

    my $package_grep = quotemeta(sprintf('%s/%s', $data->{'location'}, $data->{'package'}));
    my $checksum     = ( grep { $_ =~ /$package_grep$/} @checksums )[0] || '';
    my ($md5, $file) = split(/\s/, $checksum);

    my @row = (
      $repository,                      # repository
      $repo->{'priority'},              # priority
      $data->{'name'},                  # name
      $data->{'package'},               # package
      $data->{'version'},               # version
      $data->{'build'},                 # build
      $data->{'tag'},                   # tag
      $data->{'arch'},                  # arch
      $data->{'category'},              # category
      $data->{'summary'},               # summary
      $data->{'description'},           # description
      $data->{'mirror'} || $mirror,     # mirror
      $data->{'location'},              # location
      $data->{'required'},              # required
      $data->{'conflicts'},             # conflicts
      $data->{'suggests'},              # suggests
      $data->{'size_compressed'},       # size_compressed
      $data->{'size_uncompressed'},     # size_uncompressed
      $md5,                             # checksum
    );

    push(@values, \@row);

  }

  &$callback_status('save') if ($callback_status);

  db_bulk_insert(
    'table'   => 'packages',
    'columns' => \@columns,
    'values'  => \@values,
  );

  db_compact();

}


sub parse_manifest {

  my ($repo, $callback_status) = @_;

  my $repository        = $repo->{'id'};
  my $manifest_contents = '';

  unless(download_repository_metadata($repository, 'manifest', \&$callback_status, \&$callback_status)) {
    &$callback_status('skip') if ($callback_status);
    return(0);
  }

  my $manifest_file = sprintf("%s/%s/MANIFEST.bz2", $slackman_conf->{directory}->{'cache'}, $repository);
  return(0) unless(-e $manifest_file);

  my $manifest_input = file_read($manifest_file);
  return(0) unless($manifest_input);

  db_meta_delete("manifest-last-update.$repository");

  &$callback_status('parse') if ($callback_status);

  bunzip2 \$manifest_input => \$manifest_contents or die "bunzip2 failed: $Bunzip2Error\n";

  my @manifest = split(/\n{2,}/, $manifest_contents);

  $dbh->do('DELETE FROM manifest WHERE package_id IN (SELECT packages.id FROM packages WHERE packages.repository = ?)', undef, $repository);

  my @columns = ('package_id', 'directory', 'file');
  my @values  = ();

  my $num = 0;

  foreach my $manifest (@manifest) {

    callback_spinner($num);
    $num++;

    my @lines = split(/\n/, $manifest);

    my ($package_location) = $manifest =~ /Package:\s+(.*)/;
    my $package            = basename($package_location);
    my $location           = dirname($package_location);

    my $package_id = $dbh->selectrow_array('SELECT id FROM packages WHERE package = ? AND repository = ?', undef, $package, $repository);
    next unless($package_id);

    foreach my $line (@lines) {

      callback_spinner($num);
      $num++;

      next unless ($line =~ /^(d|-)/);

      my ($permission, $ownership, $size, $date, $time, $path) = split(/\s+/, $line);

      next if ($path eq './');
      next if ($path =~ /^install/);

      my $datetime = "$date $time";
      my ($directory, $file);

      $path = "/$path";

      if ($permission =~ /^d/) {
        $directory = $path;
        $file      = undef;
      }

      if ($permission =~ /^-/) {
        $file      = basename($path);
        $directory = dirname($path);
      }

      my @row = ( $package_id, $directory, $file );
      push(@values, \@row);

    }

  }

  &$callback_status('save') if ($callback_status);

  db_bulk_insert(
    'table'   => 'manifest',
    'columns' => \@columns,
    'values'  => \@values,
  );

  db_compact();

}


sub parse_history {

  my ($type, $callback_status) = @_;

  my $path = '';
  my $slackware_root = $ENV{ROOT} || '';

  my $installed_packages = qx{ls -l $slackware_root/var/log/packages/ | wc -l};
  my $removed_packages   = qx{ls -l $slackware_root/var/log/removed_packages/ | wc -l};
  my $last_installed     = qx{ls -lrt $slackware_root/var/log/packages/ | tail -1 | awk '{ print \$NF }'};

  chomp($installed_packages);
  chomp($removed_packages);
  chomp($last_installed);

  my $meta_installed_packages = db_meta_get('installed-packages') || 0;
  my $meta_removed_packages   = db_meta_get('removed-packages')   || 0;

  given($type) {

    when('installed') {

      return(0) if (   $installed_packages == $meta_installed_packages
                    && $removed_packages   == $meta_removed_packages);

      $path = "$slackware_root/var/log/packages";

      $dbh->do(qq/DELETE FROM history WHERE status = 'installed'/);
      db_meta_set('installed-packages', $installed_packages);

    }

    when(/(removed|upgraded)/) {

      return(0) if ($removed_packages == $meta_removed_packages);

      $path = "$slackware_root/var/log/removed_packages";

      $dbh->do(qq/DELETE FROM history WHERE status IN ('upgraded', 'removed')/);
      db_meta_set('removed-packages', $removed_packages);

    }

  }

  my @columns = qw(name package version build tag arch status timestamp upgraded
                   summary description size_compressed size_uncompressed);

  my @values  = ();

  &$callback_status('parse') if ($callback_status);

  my $num   = 0;
  my @files = grep { -f } glob("$path/*");

  foreach my $file (@files) {

    callback_spinner($num);
    $num++;

    my ($dev, $ino, $mode, $nlink, $uid, $gid, $rdev, $size,
        $atime, $mtime, $ctime, $blksize, $blocks) = stat($file);

    my $filename  = basename($file);
    my $status;
    my $timestamp = time_to_timestamp($mtime);
    my $upgraded  = '';

    if ($filename =~ /\-upgraded/) {
      $filename  =~ /\-upgraded\-(\d{4}\-\d{2}\-\d{2}),(\d{2}\:\d{2}\:\d{2})/;
      $upgraded  = "$1 $2";
      $filename  =~ s/\-upgraded(.*)//;
      $status    = 'upgraded';
    } else {
      $status = $type;
    }

    my $metadata = package_metadata(file_read($file));

    my @row = (
      $metadata->{'name'},               # name
      $filename,                         # package
      $metadata->{'version'},            # version
      $metadata->{'build'},              # build
      $metadata->{'tag'},                # tag
      $metadata->{'arch'},               # arch
      $status,                           # status
      $timestamp,                        # timestamp
      $upgraded,                         # upgraded
      $metadata->{'summary'},            # summary
      $metadata->{'description'},        # description
      $metadata->{'size_compressed'},    # size_compressed
      $metadata->{'size_uncompressed'},  # size_uncompressed
    );

    push(@values, \@row);

  }

  &$callback_status('save') if ($callback_status);

  db_bulk_insert(
    'table'   => 'history',
    'columns' => \@columns,
    'values'  => \@values,
  );

  $dbh->do('PRAGMA VACUUM');

}


sub parse_variables {

  my $string = shift;

  my $arch    = get_arch();
  my $release = get_slackware_release();

  my $arch_family    = $arch;
  my $arch_bit       = $arch;
  my $release_conf   = $release;
  my $release_suffix = '';

  $release_conf = $slackman_conf->{'slackware'}->{'version'} if (defined $slackman_conf->{'slackware'}->{'version'});

     if ($arch eq 'x86_64')        { $arch_bit = 64; }
  elsif ($arch =~ /x86|i[3456]86/) { $arch_bit = 32; $arch_family = 'x86'; }
  elsif ($arch =~ /arm(.*)/)       { $arch_bit = 32; $arch_family = 'arm'; }

  $release_suffix = $arch_family if ($arch_family eq 'arm');
  $release_suffix = $arch_bit    if ($arch_bit eq '64');

  $string =~ s/(\{|\})//g;

  $string =~ s/\$arch\.family/$arch_family/g;
  $string =~ s/\$arch\.bit/$arch_bit/g;
  $string =~ s/\$arch/$arch/g;

  $string =~ s/\$release\.suffix/$release_suffix/g;
  $string =~ s/\$release\.real/$release/g;
  $string =~ s/\$release/$release_conf/g;

  return $string;

}


sub parse_module_name {

  my $module = shift;

  return _parse_perl_module_name($module) if ($module =~ /perl\((.*)\)/);
  return $module;

}


sub _parse_perl_module_name {

  my ($module) = shift =~ /perl\((.*)\)/;
      $module =~ s/::/-/g;

  return "perl-$module";

}

1;
__END__

=head1 NAME

Slackware::SlackMan::Parser - SlackMan Parser module

=head1 SYNOPSIS

  use Slackware::SlackMan::Parser qw(:all);

  print parse_variables('Welcome to Slackware${release.suffix} $release');
  ...

=head1 DESCRIPTION

Parser module for SlackMan.

=head1 EXPORT

No subs are exported by default.

=head1 SUBROUTINES

=head2 parse_changelog

  sub callback_status {
    my $status = shift;
    print "... $status";
  }

  parse_changelog($repo, &callback_status);

C<parse_changelog> parse a standard Slackware ChangeLog.txt and save into slackman
database.


=head2 parse_checksums

  parse_checksums($repo);

C<parse_checksums> parse a standard Slackware CHECHSUMS.md5 file and save into
slackman database.


=head2 parse_history

  sub callback_status {
    my $status = shift;
    print "... $status";
  }

  parse_history('installed, $callback_status);
  ...
  parse_history('removed, $callback_status);

C<parse_history> parse a local Slackware database from C</var/log/packages>
(installed packages) and C</var/log/removed_packages> (removed and upgraded packages)
and save into slackman database.


=head2 parse_manifest

  sub callback_status {
    my $status = shift;
    print "... $status";
  }

  parse_manifest($repo, $callback_status);

C<parse_manifest> parse a standard Slackware MANIFEST.mb2 file and save into
slackman database.


=head2 parse_module_name

  parse_module_name('perl(Acme::Foo::Bar)'); # perl-Acme-Foo-Bar

C<parse_module_name> parse module name into package name.


=head2 parse_packages

  sub callback_status {
    my $status = shift;
    print "... $status";
  }

  parse_packages($repo, $callback_status);

C<parse_packages> parse a standard Slackware PACKAGES.TXT file and save into
slackman database.


=head2 parse_variables

  print parse_variables('Welcome to Slackware${release.suffix} $release');

C<parse_variables> parse all special variables used in slackman & repos.d configuration.

=over 4

=item  * C<$arch> (eg. x86_64)

=item  * C<$arch.bit> (eg. 64)

=item  * C<$arch.family> (eg. x86)

=item  * C<$release> (eg. 14.2  - from C</etc/slackware-release> or "current" if is configured in C</etc/slackman/slackman.conf>)

=item  * C<$release.real> (eg. 14.2 - from C</etc/slackware-release>)

=item  * C<$release.suffix> (eg. 64 for Slackware64, arm for Slackwarearm)

=back


=head1 AUTHOR

Giuseppe Di Terlizzi, C<< <giuseppe.diterlizzi at gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<giuseppe.diterlizzi at gmail.com>, or through
the web interface at L<https://github.com/LotarProject/slackman/issues>. I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the C<perldoc> command.

  perldoc Slackware::SlackMan::Parser

You can also look for information at:

=over 4

=item * GitHub issues (report bugs here)

L<https://github.com/LotarProject/slackman/issues>

=item * SlackMan documentation

L<https://github.com/LotarProject/slackman/wiki>

=back

=head1 LICENSE AND COPYRIGHT

Copyright 2016-2017 Giuseppe Di Terlizzi.

This module is free software, you may distribute it under the same terms
as Perl.

=cut
