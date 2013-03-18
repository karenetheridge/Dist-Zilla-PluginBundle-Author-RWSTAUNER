# vim: set ts=2 sts=2 sw=2 expandtab smarttab:
use strict;
use warnings;

package Dist::Zilla::PluginBundle::Author::RWSTAUNER;
# ABSTRACT: RWSTAUNER's Dist::Zilla config

use Moose;
use List::Util qw(first); # core
use Dist::Zilla 4.300018; # :version support for add_bundle, %V in NextRelease

with qw(
  Dist::Zilla::Role::PluginBundle::Easy
  Dist::Zilla::Role::PluginBundle::Config::Slicer
  Dist::Zilla::Role::PluginBundle::PluginRemover
);
# Dist::Zilla::Role::DynamicConfig is not necessary: payload is already dynamic

# don't require it in case it won't install somewhere
my $spelling_tests = eval 'require Dist::Zilla::Plugin::Test::PodSpelling';

# available builders
my %builders = (
  eumm => 'MakeMaker',
  mb   => 'ModuleBuild',
);

# cannot use $self->name for class methods
sub _bundle_name {
  my $class = @_ ? ref $_[0] || $_[0] : __PACKAGE__;
  join('', '@', ($class =~ /^.+::PluginBundle::(.+)$/));
}

# TODO: consider an option for using ReportPhase
sub _default_attributes {
  use Moose::Util::TypeConstraints 1.01;
  return {
    auto_prereqs    => [Bool => 1],
    fake_release    => [Bool => $ENV{DZIL_FAKERELEASE}],
    # cpanm will choose the best place to install
    install_command => [Str  => 'cpanm -v -i .'],
    is_task         => [Bool => 0],
    placeholder_comments => [Bool => 0],
    releaser        => [Str  => 'UploadToCPAN'],
    skip_plugins    => [Str  => ''],
    skip_prereqs    => [Str  => ''],
    weaver_config   => [Str  => $_[0]->_bundle_name],
    use_git_bundle  => [Bool => 1],
    builder         => [enum( [ both => keys %builders ] ) => 'eumm'],
  };
}

sub _generate_attribute {
  my ($self, $key) = @_;
  has $key => (
    is      => 'ro',
    isa     => $self->_default_attributes->{$key}[0],
    lazy    => 1,
    default => sub {
      # if it exists in the payload
      exists $_[0]->payload->{$key}
        # use it
        ?  $_[0]->payload->{$key}
        # else get it from the defaults (for subclasses)
        :  $_[0]->_default_attributes->{$key}[1];
    }
  );
}

{
  # generate attributes
  __PACKAGE__->_generate_attribute($_)
    for keys %{ __PACKAGE__->_default_attributes };
}

around BUILDARGS => sub {
  my ($orig, $class, @args) = @_;
  my $attr = $class->$orig(@args);
  foreach my $gone ( qw( disable_tests ) ){
    if( $attr->{ $gone } ){
      die "$class no longer supports '$gone'.\n  Please use the '-remove' attribute instead\n";
    }
  }
  return $attr;
};

# main
after configure => sub {
  my ($self) = @_;

  my $skip = $self->skip_plugins;
  $skip &&= qr/$skip/;

  my $dynamic = $self->payload;
  # sneak this config in behind @TestingMania's back
  $dynamic->{'Test::Compile.fake_home'} = 1
    unless first { /Test::Compile\W+fake_home/ } keys %$dynamic;

  my $plugins = $self->plugins;

  my $i = -1;
  while( ++$i < @$plugins ){
    my $spec = $plugins->[$i] or next;
    # NOTE: $conf retains its reference (modifications alter $spec)
    my ($name, $class, $conf) = @$spec;

    # ignore the prefix (@Bundle/Name => Name) (DZP::Name => Name)
    my ($alias)   = ($name  =~ m#([^/]+)$#);
    my ($moniker) = ($class =~ m#^(?:Dist::Zilla::Plugin(?:Bundle)?::)?(.+)$#);

    # exclude any plugins that match 'skip_plugins'
    if( $skip ){
      # match on full name or plugin class (regexp should use \b not \A)
      if( $name =~ $skip || $class =~ $skip ){
        splice(@$plugins, $i, 1);
        redo;
      }
    }
  }
  if ( $ENV{DZIL_BUNDLE_DEBUG} ) {
    eval {
      require YAML::Tiny; # dzil requires this
      $self->log( YAML::Tiny::Dump( $self->plugins ) );
    };
    warn $@ if $@;
  }
};

sub configure {
  my ($self) = @_;

  $self->log_fatal("you must not specify both weaver_config and is_task")
    if $self->is_task and $self->weaver_config ne $self->_bundle_name;

  $self->add_plugins(

  # provide version
    #'Git::DescribeVersion',
    'Git::NextVersion',

  # gather and prune
    $self->_generate_manifest_skip,
    qw(
      GatherDir
      PruneCruft
      ManifestSkip
    ),
    # Devel::Cover db does not need to be packaged with distribution
    [ PruneFiles => 'PruneDevelCoverDatabase' => { match => '^(cover_db/.+)' } ],
    # Code::Stat report
    [ PruneFiles => 'PruneCodeStatCollection' => { match => '^codestat\.out' } ],

  # munge files
    [
      Authority => {
        ':version'     => '1.005', # accepts any non-whitespace + locate_comment
        do_munging     => 1,
        do_metadata    => 1,
        locate_comment => $self->placeholder_comments,
      }
    ],
    [
      NextRelease => {
        # w3cdtf
        time_zone => 'UTC',
        format => q[%-9V %{yyyy-MM-dd'T'HH:mm:ss'Z'}d],
      }
    ],
    ($self->placeholder_comments ? 'OurPkgVersion' : 'PkgVersion'),
    [
      Prepender => {
        ':version' => '1.112280', # 'skip' attribute
        # don't prepend to tests
        skip => '^x?t/.+',
      }
    ],
    ( $self->is_task
      ?  'TaskWeaver'
      # TODO: detect weaver.ini and skip 'config_plugin'?
      : [ 'PodWeaver' => { config_plugin => $self->weaver_config } ]
    ),

  # generated distribution files
    qw(
      License
      Readme
    ),
    [
      # generate README.pod in repo root for github
      ReadmeAnyFromPod => {
        ':version' => '0.120120',
        type       => 'pod',
        location   => 'root',
      }
    ],

  # metadata
    'Bugtracker',
    # won't find git if not in repository root (!-e ".git")
    [ Repository => { ':version' => '0.16' } ], # deprecates github_http
    # overrides [Repository] if repository is on github
    [ GithubMeta => { ':version' => '0.10' } ],
  );

  $self->add_plugins(
    [ AutoPrereqs => $self->config_slice({ skip_prereqs => 'skip' }) ]
  )
    if $self->auto_prereqs;

  $self->add_plugins(
#   [ 'MetaData::BuiltWith' => { show_uname => 1 } ], # currently DZ::Util::EmulatePhase causes problems
    [
      MetaNoIndex => {
        ':version' => 1.101130,
        # could use grep { -d $_ } but that will miss any generated files
        directory => [qw(corpus examples inc share t xt)],
        namespace => [qw(Local t::lib)],
        'package' => [qw(DB)],
      }
    ],
    [   # AFTER MetaNoIndex
      'MetaProvides::Package' => {
        ':version'   => '1.14000001',
        meta_noindex => 1
      }
    ],

    [ MinimumPerl => { ':version' => '1.003' } ],
    qw(
      MetaConfig
      MetaYAML
      MetaJSON
    ),

# I prefer to be explicit about required versions when loading, but this is a handy example:
#    [
#      Prereqs => 'TestMoreWithSubtests' => {
#        -phase => 'test',
#        -type  => 'requires',
#        'Test::More' => '0.96'
#      }
#    ],

  # build system
    qw(
      ExecDir
      ShareDir
    ),
  );

  {
    my @builders = $self->builder eq 'both'
      ? (values %builders, 'DualBuilders')
      : ($builders{ $self->builder });
    $self->log("Including builders: @builders\n");
    $self->add_plugins(@builders);
  }

  $self->add_plugins(
  # generated t/ tests
    [ 'Test::ReportPrereqs' => { ':version' => '0.004' } ], # include/exclude

  # generated xt/ tests
    # Test::Pod::Spelling::CommonMistakes ?
      #Test::Pod::No404s # removed since it's rarely useful
  );
  if ( $spelling_tests ) {
    $self->add_plugins('Test::PodSpelling');
  }
  else {
    $self->log("Test::PodSpelling Plugin failed to load.  Pleese dunt mayke ani misteaks.\n");
  }

  # NOTE: A newer TestingMania might duplicate plugins if new tests are added
  $self->add_bundle('@TestingMania' => {
    ':version' => '0.014',
  });

  $self->add_plugins(
  # manifest: must come after all generated files
    'Manifest',

  # before release
    qw(
      CheckExtraTests
    ),
    [ CheckChangesHasContent => { ':version' => '0.006' } ], # version-TRIAL
    qw(
      TestRelease
    ),

  );

  # defaults: { tag_format => '%v', push_to => [ qw(origin) ] }
  $self->add_bundle('@Git' => {
    ':version' => '2.004', # improved changelog parsing
    allow_dirty => [qw(Changes README.pod)],
    commit_msg  => 'v%v%t%n%n%c'
  })
    if $self->use_git_bundle;

  $self->add_plugins(
    qw(
      ConfirmRelease
    ),
  );

  # release
  my $releaser = $self->fake_release ? 'FakeRelease' : $self->releaser;
  # ignore releaser if it's set to empty string
  $self->add_plugins($releaser)
    if $releaser;

  $self->add_plugins(
    [ InstallRelease => { ':version' => '0.006', install_command => $self->install_command } ]
  )
    if $self->install_command;

}

# As of Dist::Zilla 4.102345 pluginbundles don't have log and log_fatal methods
foreach my $method ( qw(log log_fatal) ){
  unless( __PACKAGE__->can($method) ){
    no strict 'refs'; ## no critic (NoStrict)
    *$method = $method =~ /fatal/
      ? sub { die($_[1]) }
      : sub { warn("[${\$_[0]->_bundle_name}] $_[1]") };
  }
}

sub _generate_manifest_skip {
  # include a default MANIFEST.SKIP for the tests and/or historical reasons
  return [
    GenerateFile => 'GenerateManifestSkip' => {
      filename => 'MANIFEST.SKIP',
      is_template => 1,
      content => <<'EOF_MANIFEST_SKIP',

\B\.git\b
\B\.gitignore$
^[\._]build
^blib/
^(Build|Makefile)$
\bpm_to_blib$
^MYMETA\.

EOF_MANIFEST_SKIP
    }
  ];
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

=for stopwords PluginBundle PluginBundles DAGOLDEN RJBS dists ini arrayrefs
releaser

=for Pod::Coverage configure
log log_fatal

=head1 SYNOPSIS

  # dist.ini

  [@Author::RWSTAUNER]

=head1 DESCRIPTION

This is an Author
L<Dist::Zilla::PluginBundle|Dist::Zilla::Role::PluginBundle::Easy>
that I use for building my dists.

This Bundle was heavily influenced by the bundles of
L<RJBS|Dist::Zilla::PluginBundle::RJBS> and
L<DAGOLDEN|Dist::Zilla::PluginBundle::DAGOLDEN>.

=head1 CONFIGURATION

Possible options and their default values:

  auto_prereqs   = 1  ; enable AutoPrereqs
  builder        = eumm ; or 'mb' or 'both'
  fake_release   = 0  ; if true will use FakeRelease instead of 'releaser'
  install_command = cpanm -v -i . (passed to InstallRelease)
  is_task        = 0  ; set to true to use TaskWeaver instead of PodWeaver
  placeholder_comments = 0 ; use '# VERSION' and '# AUTHORITY' comments
  releaser       = UploadToCPAN
  skip_plugins   =    ; default empty; a regexp of plugin names to exclude
  skip_prereqs   =    ; default empty; corresponds to AutoPrereqs.skip
  weaver_config  = @Author::RWSTAUNER

The C<fake_release> option also respects C<$ENV{DZIL_FAKERELEASE}>.

The C<release> option can be set to an alternate releaser plugin
or to an empty string to disable adding a releaser.
This can make it easier to include a plugin that requires configuration
by just ignoring the default releaser and including your own normally.

B<NOTE>:
This bundle consumes L<Dist::Zilla::Role::PluginBundle::Config::Slicer>
so you can also specify attributes for any of the bundled plugins.
The option should be the plugin name and the attribute separated by a dot:

  [@Author::RWSTAUNER]
  AutoPrereqs.skip = Bad::Module

B<Note> that this is different than

  [@Author::RWSTAUNER]
  [AutoPrereqs]
  skip = Bad::Module

which will load the plugin a second time.
The first example actually alters the plugin configuration
as it is included by the Bundle.

See L<Config::MVP::Slicer/CONFIGURATION SYNTAX> for more information.

If your situation is more complicated you can use the C<-remove> attribute
(courtesy of L<Dist::Zilla::Role::PluginBundle::PluginRemover>)
to have the Bundle ignore that plugin
and then you can add it yourself:

  [MetaNoIndex]
  directory = one-dir
  directory = another-dir
  [@Author::RWSTAUNER]
  -remove = MetaNoIndex

C<-remove> can be specified multiple times.

Alternatively you can use the C<skip_plugins> attribute (only once)
which is a regular expression that matches plugin name or package.

  [@Author::RWSTAUNER]
  skip_plugins = MetaNoIndex|SomethingElse

=head1 EQUIVALENT F<dist.ini>

This bundle is roughly equivalent to:

  [Git::NextVersion]      ; autoincrement version from last tag

  ; choose files to include (dzil core [@Basic])
  [GatherDir]             ; everything under top dir
  [PruneCruft]            ; default stuff to skip
  [ManifestSkip]          ; custom stuff to skip

  ; munge files
  [Authority]             ; inject $AUTHORITY into modules
  do_metadata = 1         ; default
  [NextRelease]           ; simplify maintenance of Changes file
  ; use W3CDTF format for release timestamps (for unambiguous dates)
  time_zone = UTC
  format    = %-9v %{yyyy-MM-dd'T'HH:mm:ss'Z'}d
  [PkgVersion]            ; inject $VERSION (use OurPkgVersion if 'placeholder_comments')
  [Prepender]             ; add header to source code files

  [PodWeaver]             ; munge POD in all modules
  config_plugin = @Author::RWSTAUNER
  ; 'weaver_config' can be set to an alternate Bundle
  ; set 'is_task = 1' to use TaskWeaver instead

  ; generate files
  [License]               ; generate distribution files (dzil core [@Basic])
  [Readme]                ; simple readme for inclusion in release dist ([@Basic])

  [ReadmeAnyFromPod]      ; generate repo-root README.pod from main_module for github
  type = pod
  location = root

  ; metadata
  [Bugtracker]            ; include bugtracker URL and email address (uses RT)
  [Repository]            ; determine git information (if -e ".git")
  [GithubMeta]            ; overrides [Repository] if repository is on github

  [AutoPrereqs]
  ; disable with 'auto_prereqs = 0'

  [MetaNoIndex]           ; encourage CPAN not to index:
  directory = corpus
  directory = examples
  directory = inc
  directory = share
  directory = t
  directory = xt
  namespace = Local
  namespace = t::lib
  package   = DB

  [MetaProvides::Package] ; describe packages included in the dist
  meta_noindex = 1        ; ignore things excluded by above MetaNoIndex

  [MinimumPerl]           ; automatically determine Perl version required

  [MetaConfig]            ; include Dist::Zilla info in distmeta (dzil core)
  [MetaYAML]              ; include META.yml (v1.4) (dzil core [@Basic])
  [MetaJSON]              ; include META.json (v2) (more info than META.yml)

  [Prereqs / TestRequires]
  Test::More = 0.96       ; require recent Test::More (including subtests)

  [ExtraTests]            ; build system (dzil core [@Basic])
  [ExecDir]               ; include 'bin/*' as executables
  [ShareDir]              ; include 'share/' for File::ShareDir

  [MakeMaker]             ; create Makefile.PL (if builder == 'eumm' (default))
  ; [ModuleBuild]         ; create Build.PL (if builder == 'mb')
  ; [DualBuilders]        ; only require one of the above two (prefer 'build') (if both)

  ; generate t/ and xt/ tests
  [ReportVersions::Tiny]  ; show module versions used in test reports
  [@TestingMania]         ; Lots of dist tests
  [Test::PodSpelling]     ; spell check POD (if installed)

  [Manifest]              ; build MANIFEST file (dzil core [@Basic])

  ; actions for releasing the distribution (dzil core [@Basic])
  [CheckExtraTests]       ; xt/
  [CheckChangesHasContent]
  [TestRelease]           ; run tests before releasing

  [@Git]                  ; use Git bundle to commit/tag/push after releasing
  allow_dirty = Changes README.mkdn

  [ConfirmRelease]        ; are you sure?
  [UploadToCPAN]
  ; see CONFIGURATION for alternate Release plugin configuration options

  [InstallRelease]        ; install the new dist (using 'install_command')

=head1 SEE ALSO

=for :list
* L<Dist::Zilla>
* L<Dist::Zilla::Role::PluginBundle::Easy>
* L<Dist::Zilla::Role::PluginBundle::Config::Slicer>
* L<Dist::Zilla::Role::PluginBundle::PluginRemover>
* L<Pod::Weaver>

=cut
