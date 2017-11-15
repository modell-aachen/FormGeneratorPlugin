# See bottom of file for license and copyright information
use strict;
use warnings;

package FormGeneratorPluginTests;

use FoswikiFnTestCase;
our @ISA = qw( FoswikiFnTestCase );

use strict;
use warnings;

use Foswiki();
use Error qw ( :try );
use Foswiki::Plugins::FormGeneratorPlugin();
use Test::MockModule;

my $mocks; # mocks will be stored in a package variable, so we can unmock them reliably when the test finished

sub tear_down {
    my $this = shift;

    foreach my $module (keys %$mocks) {
        $mocks->{$module}->unmock_all();
    }

    $this->SUPER::tear_down();
}

sub new {
    my ($class, @args) = @_;
    my $this = shift()->SUPER::new('FormGeneratorPluginTests', @args);
    return $this;
}

sub loadExtraConfig {
    my $this = shift;
    $this->SUPER::loadExtraConfig();
    $Foswiki::cfg{Plugins}{FormGeneratorPlugin}{Enabled} = 1;
}

# Test if...
# ...ExtraFields from other forms and non-ExtraFields get removed
# ...names get sorted alphabetically (LocalExtraField after ExtraField)
# ...the digits get sorted numerically
sub test_sortExtraFieldTopics {
    my ( $this ) = @_;

    # Originally I wanted to split this into separate tests, however calling
    # Foswiki::Plugins::FormGeneratorPlugin::_sortExtraFields turned out to be
    # quite a hassle, so it got put into a single thing.

    $mocks->{'Foswiki::Func'} = Test::MockModule->new('Foswiki::Func');
    $mocks->{'Foswiki::Func'}->mock('getTopicList', sub{ return qw( MyFormExtraFields3 OtherFormExtraFields1 MyFormExtraFields1 MyFormExtraFields10 MyFormLocalExtraFields1 MyFormLocalExtraFields100 MyFormExtraFields2 Dummy DummyFormLocalExtraFields ); });

    my @extraFieldTopics = Foswiki::Plugins::FormGeneratorPlugin::_getExtraFieldTopics('TestWeb', 'MyForm');

    my $result = join(' ', @extraFieldTopics);
    $this->assert($result, "TestWeb.MyFormExtraFields1 TestWeb.MyFormExtraFields2 TestWeb.MyFormExtraFields3 TestWeb.MyFormExtraFields10 TestWeb.MyFormLocalExtraFields1 TestWeb.MyFormLocalExtraFields100");
}

1;
__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Author: Modell Aachen GmbH

Copyright (C) 2008-2011 Foswiki Contributors. Foswiki Contributors
are listed in the AUTHORS file in the root of this distribution.
NOTE: Please extend that file, not this notice.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.

