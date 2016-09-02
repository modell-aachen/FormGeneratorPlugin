# See bottom of file for default license and copyright information

package Foswiki::Plugins::FormGeneratorPlugin;

use strict;
use warnings;

use Foswiki::Func    ();    # The plugins API
use Foswiki::Plugins ();    # For the API version
use Foswiki::Plugins::KVPPlugin;

use JSON;
use DBI;

our $VERSION = '1.0';
our $RELEASE = '1.0';

our $SHORTDESCRIPTION = 'Automatically generate forms from multiple rules.';

our $NO_PREFS_IN_TOPIC = 1;

my $db;
my %schema_versions;
my @schema_updates = (
    [
        # Basic relations
        "CREATE TABLE meta (type TEXT NOT NULL UNIQUE, version INT NOT NULL)",
        "INSERT INTO meta (type, version) VALUES('core', 0)",
        "CREATE TABLE formmanagers (
            webtopic TEXT NOT NULL UNIQUE,
            FormGroup TEXT NOT NULL
        )",
        "CREATE TABLE rules (
            webtopic TEXT NOT NULL UNIQUE,
            TargetFormGroup TEXT NOT NULL,
            SourceTopicForm TEXT
        )",
    ]
);

sub initPlugin {
    my ( $topic, $web, $user, $installWeb ) = @_;

    # check for Plugins.pm versions
    if ( $Foswiki::Plugins::VERSION < 2.3 ) {
        Foswiki::Func::writeWarning( 'Version mismatch between ',
            __PACKAGE__, ' and Plugins.pm' );
        return 0;
    }

    my %restopts = (authenticate => 1, validate => 0, http_allow => 'GET');
    Foswiki::Func::registerRESTHandler( 'index', \&restIndex, %restopts );

    Foswiki::Func::registerTagHandler(
        'FORMGENERATORS', \&_tagFORMGENERATORS );

    # Plugin correctly initialized
    return 1;
}

sub finishPlugin {
    undef $db;
}

sub _isEnabled {
    my ($meta) = @_;

    my $deactivated = $meta->get('PREFERENCE', 'FormGenerator_Disabled');
    return 0 if $deactivated && $deactivated->{value};
    return 1;
}

sub _checkCondition {
    my ($meta) = @_;

    my $condition = $Foswiki::cfg{Extensions}{FormGeneratorPlugin}{Condition};
    return 1 unless defined $condition && $condition ne '';

    return Foswiki::Func::isTrue($meta->expandMacros($condition));
}

sub _checkUseGenerator {
    my ($meta) = @_;

    return _isEnabled($meta) && _checkCondition($meta);
}

# Rebuild index using SolrPlugin.
sub restIndex {
    my ( $session, $subject, $verb, $response ) = @_;

    return 'NotAnAdmin' unless Foswiki::Func::isAnAdmin();

    my $db = db();

    my $groups = {};

    # get stuff
    # Note: %SEARCH% and %SOLRSEARCH% will not search webs starting with an
    # underscore. Both should by default also not search Trash, but better save
    # than sorry, since it can be configured otherwise.

    my ($forms, $rules);
    my $query = Foswiki::Func::getCgiQuery();
    my $mode = $query->param('mode');
    if($mode && $mode eq 'nosolr') {
        # We can not use solr, fallback to SEARCH
        # If anyone knows how to extract preferences via SEARCH, please change this

        # forms
        my @formsArray = split(',', Foswiki::Func::expandCommonVariables(<<'SEARCH'));
%SEARCH{
   "preferences.FormGenerator_Group.value"
   topic="*FormManager"
   web="all,-%QUERY{"{TrashWebName}"}%"
   type="query"
   nonoise="1"
   format="$web.$topic"
   separator=","
}%
SEARCH
        $forms = { response => { docs => [] } };
        foreach my $form ( @formsArray ) {
            my ($web, $topic) = Foswiki::Func::normalizeWebTopicName(undef, $form);
            my ($meta) = Foswiki::Func::readTopic($web, $topic);
            my $doc = {
                webtopic => "$web.$topic",
                preference_FormGenerator_Group_s => $meta->getPreference('FormGenerator_Group')
            };
            push @{$forms->{response}->{docs}}, $doc;
        }

        # generators
        my $gwebs = join(',', @{$Foswiki::cfg{Extensions}{FormGeneratorPlugin}{FormGeneratorWebs}});
        my @rulesArray = split(',', Foswiki::Func::expandCommonVariables(<<"SEARCH"));
%SEARCH{
   "preferences.FormGenerator_TargetFormGroup.value"
   topic="FormGenerator_*"
   web="$gwebs"
   type="query"
   nonoise="1"
   format="\$web.\$topic"
   separator=","
}%
SEARCH
        $rules = { response => { docs => [] } };
        foreach my $rule ( @rulesArray ) {
            my ($web, $topic) = Foswiki::Func::normalizeWebTopicName(undef, $rule);
            my ($meta) = Foswiki::Func::readTopic($web, $topic);
            my $doc = {
                webtopic => "$web.$topic",
                preference_FormGenerator_TargetFormGroup_s => $meta->getPreference('FormGenerator_TargetFormGroup'),
                preference_FormGenerator_SourceTopicForm_s => $meta->getPreference('FormGenerator_SourceTopicForm')
            };
            push @{$rules->{response}->{docs}}, $doc;
        }
    } else {
        my $solr = Foswiki::Plugins::SolrPlugin->getSearcher();

        my $raw = $solr->solrSearch("topic:*FormManager preference_FormGenerator_Group_s:* -web:$Foswiki::cfg{TrashWebName}", {rows => 9999, fl => "webtopic,preference_FormGenerator_Group_s"})->{raw_response};
        $forms = from_json($raw->{_content});

        my $gwebs = join(' OR ', @{$Foswiki::cfg{Extensions}{FormGeneratorPlugin}{FormGeneratorWebs}});
        $raw = $solr->solrSearch("topic:FormGenerator_* preference_FormGenerator_TargetFormGroup_s:* web:($gwebs)", {rows => 9999, fl => "webtopic,preference_FormGenerator_TargetFormGroup_s,preference_FormGenerator_SourceTopicForm_s"})->{raw_response};
        $rules = from_json($raw->{_content});
    }

    # clean old tables (make sure there are no leftovers from deleted topics)

    $db->do("DELETE from rules");
    $db->do("DELETE from formmanagers");

    # insert new stuff

    foreach my $form ( @{$forms->{response}->{docs}} ) {
        $db->do("INSERT OR REPLACE into formmanagers (webtopic, FormGroup) values (?, ?)", {}, $form->{webtopic}, $form->{preference_FormGenerator_Group_s});
        $groups->{$form->{preference_FormGenerator_Group_s}} = 1;
    }

    foreach my $rule ( @{$rules->{response}->{docs}} ) {
       $db->do("INSERT OR REPLACE into rules (webtopic, TargetFormGroup, SourceTopicForm) values (?, ?, ?)", {}, $rule->{webtopic}, $rule->{preference_FormGenerator_TargetFormGroup_s}, $rule->{preference_FormGenerator_SourceTopicForm_s});
        $groups->{$rule->{preference_FormGenerator_TargetFormGroup_s}} = 1;
    }

    # generate
    if($query->param('generate')) {
        my @collectedGroups = keys %$groups;
        _generate(\@collectedGroups);
    }

    # finished

    return 'OK';
}

sub _tagFORMGENERATORS {
    my ( $session, $attributes, $topic, $web ) = @_;

    my $group = $attributes->{_DEFAULT} || '';
    my @rules = _getRulesByGroup($group);

    my $form = $attributes->{form};
    if($form) {
        my ($web, $topic) = Foswiki::Func::normalizeWebTopicName(undef, $form);
        my $customization = $topic."ExtraFields";
        my $extraIdx = 0;
        while (Foswiki::Func::topicExists($web, $customization . ++$extraIdx)) {
            push @rules, "$web.$customization$extraIdx";
        }
    }

    my @result = ();
    foreach my $rule ( @rules ) {
        my ($ruleWeb, $ruleTopic) = Foswiki::Func::normalizeWebTopicName(undef, $rule);
        my ($meta) = Foswiki::Func::readTopic($ruleWeb, $ruleTopic);

        push @result, "$rule " . (_checkUseGenerator($meta) ? 'used' : 'unused');
    }
    return join(',', @result);
}

# Manages topic changes.
#    * Update db
#    * generate new form
#
# Parameters:
#    * oldWeb: previous web, may be identical to newWeb
#    * oldTopic: previous topic, may be identical to newTopic; may be undef (web-rename)
#    * newWeb: name of current web
#    * newTopic: current topic name; may be undef (web-rename)
#    * newMeta: current meta object; may only be undef if newTopic is undef
sub _onChange {
    my ($oldWeb, $oldTopic, $newWeb, $newTopic, $newMeta) = @_;

    # Update db

    my $db = db();
    if($oldTopic && $oldTopic =~ m#^FormGenerator_#) {
        $db->do("DELETE from rules WHERE webtopic=?", {}, "$oldWeb.$oldTopic");
        if($newTopic =~ m#^FormGenerator_# && scalar grep{$_ eq $newWeb} @{$Foswiki::cfg{Extensions}{FormGeneratorPlugin}{FormGeneratorWebs}}) {
            my $formGroup = $newMeta->getPreference('FormGenerator_TargetFormGroup');
            my $sourceForm = $newMeta->getPreference('FormGenerator_SourceTopicForm');
            $db->do("INSERT into rules (webtopic, TargetFormGroup, SourceTopicForm) values (?, ?, ?)", {}, "$newWeb.$newTopic", $formGroup, $sourceForm) if $formGroup;
        }
    } elsif($oldTopic && $oldTopic =~ m#FormManager$#) {
        $db->do("DELETE from formmanagers WHERE webtopic=?", {}, "$oldWeb.$oldTopic");
        if($newTopic =~ m#FormManager$# && $newWeb ne $Foswiki::cfg{TrashWebName}) {
            my $formGroup = $newMeta->getPreference('FormGenerator_Group');
            $db->do("INSERT into formmanagers (webtopic, FormGroup) values (?, ?)", {}, "$newWeb.$newTopic", $formGroup) if $formGroup;
        }
    } elsif(not $oldTopic) {
        if($newWeb =~ m#^\Q$Foswiki::cfg{TrashWebName}\E(?:$|/|\.)#) {
            # web was moved to trash, delete from index
            $db->do("DELETE from rules WHERE webtopic LIKE ?", {}, "$oldWeb.\%");
            $db->do("DELETE from formmanagers WHERE webtopic LIKE ?", {}, "$oldWeb.\%");
        } else {
            $db->do("UPDATE formmanagers SET webtopic=? || substr(webtopic,?) WHERE webtopic LIKE ?", {}, "$newWeb.", length($oldWeb)+1, "$oldWeb.\%");
        }
    }

    # Update forms

    my %groups;

    if ((not $newTopic) || $newTopic eq 'WebPreferences' || $newTopic eq 'SitePreferences') { # Note: One may create MyWeb.SitePreferences, however not worth the effort
        my @allGroups = @{ db()->selectcol_arrayref("SELECT DISTINCT TargetFormGroup from rules") };
        foreach my $group (@allGroups) {
            next unless $group;
            $groups{$group} = 1;
        }
    } elsif ($newTopic =~ /^FormGenerator_/) {
        $groups{$newMeta->getPreference('FormGenerator_TargetFormGroup')} = 1;
    } elsif ($newTopic =~ /FormManager$/) {
        $groups{$newMeta->getPreference('FormGenerator_Group')} = 1;
    } elsif ($newTopic =~ /^(.*Form)ExtraFields\d+$/) {
        my $formManager = "$1Manager";
        if (Foswiki::Func::topicExists($newWeb, $formManager)) {
            ($formManager) = Foswiki::Func::readTopic($newWeb, $formManager);
            my $target = $formManager->getPreference('FormGenerator_Group');
            $groups{$target} = 1 if $target;
        }
    } elsif ($newMeta) {
        my $newForm = $newMeta->getFormName();
        if($newForm) {
            $newForm =~ s#.*[./]##;

            my @grps = @{ db()->selectcol_arrayref("SELECT DISTINCT TargetFormGroup FROM rules WHERE SourceTopicForm=?",{}, $newForm) };
            foreach my $g (@grps) {
                $groups{$g} = 1;
            }
        }
    }

    my @collectedGroups = keys %groups;
    return unless scalar @collectedGroups;
    _generate(\@collectedGroups);
}

sub db {
    return $db if defined $db;
    $db = DBI->connect("DBI:SQLite:dbname=".Foswiki::Func::getWorkArea('FormGeneratorPlugin')."/cache.db",
        '', # user
        '', # pwd
        {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
            FetchHashKeyName => 'NAME_lc',
            sqlite_unicode => $Foswiki::UNICODE ? 1 : 0
        }
    );
    eval {
        %schema_versions = %{ $db->selectall_hashref("SELECT * FROM meta", 'type') };
    };
    _applySchema('core', @schema_updates);
    $db;
}
sub _applySchema {
    my $type = shift;
    if (!$schema_versions{$type}) {
        $schema_versions{$type} = { version => 0 };
    }
    my $v = $schema_versions{$type}{version};
    return if $v >= @_;
    for my $schema (@_[$v..$#_]) {
        $db->begin_work;
        for my $s (@$schema) {
            if (ref($s) eq 'CODE') {
                $s->($db);
            } else {
                $db->do($s);
            }
        }
        $db->do("UPDATE meta SET version=? WHERE type=?", {}, ++$v, $type);
        $db->commit;
    }
}

sub _mayEditTopic {
    my ($web, $topic, $meta) = @_;

    # XXX: an admin may create a generator outside of an allowed web, however
    # it will not be considered during generation and no message will be shown
    return 1 if Foswiki::Func::isAnAdmin();

    return 1 unless defined $topic;

    return 1 if $web eq $Foswiki::cfg{TrashWebName};

    if($topic =~ m#^FormGenerator_#) {
        return scalar grep{$_ eq $web} @{$Foswiki::cfg{Extensions}{FormGeneratorPlugin}{FormGeneratorWebs}};
    } elsif ($topic =~ m#FormExtraFields\d+$#) {
        # XXX: In KVPPlugin we trust. We have no choice, because the
        # expandMacros call will not succeed.
        return 1 if Foswiki::Plugins::KVPPlugin::isStateChange();

        my $cuid = Foswiki::Func::getCanonicalUserID();

        my $cfg = $Foswiki::cfg{Extensions}{FormGeneratorPlugin}{AllowExtraFields};
        $cfg = $meta->expandMacros($cfg);
        $cfg =~ s#\s##g;
        my @allowed = split(',', $cfg);

        foreach my $allowed ( @allowed ) {
            if(Foswiki::Func::isGroup($allowed)) {
                return 1 if Foswiki::Func::isGroupMember($allowed, $cuid, {expand => 1});
                next;
            }

            return 1 if $allowed eq 'LOGGEDIN' && !Foswiki::Func::isGuest();

            $allowed = Foswiki::Func::getCanonicalUserID($allowed);
            return 1 if defined $allowed && $allowed eq $cuid;
        }
        return 0;
    }
    return 1;
}

#   * Record changes of generators/managers
#   * Inhibit creation of generators when not permitted
sub afterRenameHandler {
    my ($web, $topic, $attachment, $newWeb, $newTopic) = @_;

    return if $attachment;

    my ($meta) = Foswiki::Func::readTopic($newWeb, $newTopic) if defined $newTopic;

    unless(_mayEditTopic($newWeb, $newTopic, $meta)) {
        # XXX: I can not inhibit the rename in the first place, so I will try
        # to repair the damage by disabling this.
        #
        # XXX: It is still possible to delete an ExtraFields topic.

        # find new place
        my $inhibitedTopic = "Inhibited$newTopic";
        my $inhibitedBase = $inhibitedTopic;
        my $c = 0;
        while(Foswiki::Func::topicExists($newWeb, $inhibitedTopic)) {
            $inhibitedTopic = $inhibitedBase . ++$c;
        }

        # move it there and record the change
        my $session = $Foswiki::Plugins::SESSION;
        my $inhibitedMeta = Foswiki::Meta->new($session, $newWeb, $inhibitedTopic);
        $meta->move($inhibitedMeta);
        _onChange($web, $topic, $newWeb, $inhibitedTopic, $meta);

        # Notify the user
        my $message = Foswiki::Func::expandCommonVariables('%MAKETEXT{"Editing form generators is restricted. The topic has been renamed."}%');
        throw Foswiki::OopsException(
            'accessdenied',
            status => 403,
            def    => 'topic_access',
            web    => $_[2],
            topic  => $_[1],
            params => [
                'Edit topic',
                $message
            ]
        );
    }

    _onChange($web, $topic, $newWeb, $newTopic, $meta);
}

# Will inhibit the save, if the user may not modify the generators.
sub beforeSaveHandler {
    my ( $text, $topic, $web, $newMeta ) = @_;

    unless(_mayEditTopic($web, $topic, $newMeta)) {
        my $message = Foswiki::Func::expandCommonVariables('%MAKETEXT{"Editing form generators is restricted."}%');
        throw Foswiki::OopsException(
            'accessdenied',
            status => 403,
            def    => 'topic_access',
            web    => $_[2],
            topic  => $_[1],
            params => [
                'Edit topic',
                $message
            ]
        );
    }
}

# Record changes of generators.
sub afterSaveHandler {
    my ( $text, $topic, $web, undef, $newMeta ) = @_;

    _onChange($web, $topic, $web, $topic, $newMeta);
}

# Get all managers indexed (ie outside Trash).
#
# Params:
#    * groups (ARRAYREF): groups which affect forms
#
# Returns:
#    * (ARRAYREF) of forms (webtopic)
sub _getAllManagers {
    my $query = "SELECT DISTINCT webtopic FROM formmanagers";
    return db()->selectcol_arrayref($query, {});
}

# Get all managers that are affected by a list of groups.
#
# Params:
#    * groups (ARRAYREF): groups which affect forms/managers
#
# Returns:
#    * (ARRAYREF) of managers (webtopic)
sub _getManagersByGroup {
    my ($groups) = @_;
    my $query = "SELECT DISTINCT webtopic FROM formmanagers WHERE FormGroup IN (". join(', ', map {'?'} @$groups) .")";
    return db()->selectcol_arrayref($query, {}, @$groups);
}

# Get all rules that affect a (single) group.
#
# Params:
#    * group: the group
#
# Returns:
#    * (ARRAYREF) of rules (webtopic)
sub _getRulesByGroup {
    my ($group) = @_;
    return @{ db()->selectcol_arrayref("SELECT DISTINCT webtopic FROM rules WHERE TargetFormGroup=?", {}, $group) };
}

# Generates (and saves) all forms affected by the groups.
# The forms are only saved, if they actually changed.
#
# Params:
#    * gropus (ARRAYREF): the groups that changed
sub _generate {
    my ($groups) = @_;

    # make sure we can read all topics (eg. for %SEARCH{...}%)
    local $Foswiki::Plugins::SESSION->{user} = 'BaseUserMapping_333';

    my %groupdata;

    my $affectedForms = _getManagersByGroup($groups);

    my $errors = '';

    # read in rules
    foreach my $group ( @$groups ) {
        my $grp = [];
        $groupdata{$group} = $grp;
        foreach my $ruleTopic ( _getRulesByGroup($group) ) {
            my ($ruleWeb, $ruleTopic) = Foswiki::Func::normalizeWebTopicName(undef, $ruleTopic);
            my ($ruleMeta, $rule) = Foswiki::Func::readTopic($ruleWeb, $ruleTopic);
            push @$grp, $ruleMeta if _checkUseGenerator($ruleMeta);

        }
    }

    # build the actual form

    foreach my $formManagerWebTopic ( @$affectedForms ) {
        my ($web, $formManagerTopic) = Foswiki::Func::normalizeWebTopicName(undef, $formManagerWebTopic);
        my $formTopic = $formManagerTopic;
        $formTopic =~ s#Manager$##;

        my ($formMeta, $oldText) = Foswiki::Func::readTopic($web, $formTopic);

        # do nothing if the form has not been autogenerated
        if(Foswiki::Func::topicExists($web, $formTopic)) {
            unless($formMeta->getPreference('FormGenerator_AUTOGENERATED')) {
                Foswiki::Func::writeWarning("Manager for non-generated form: $web.$formManagerTopic");
                next;
            }
        }

        my ($formManagerMeta) = Foswiki::Func::readTopic($web, $formManagerTopic);
        my $customization = $formTopic."ExtraFields";
        my $formRules = [@{$groupdata{$formManagerMeta->getPreference('FormGenerator_Group')}}];

        my $extraIdx = 0;
        while (Foswiki::Func::topicExists($formMeta->web(), $customization . ++$extraIdx)) {
            my $currentCustomization = "$customization$extraIdx";
            my ($customizedMeta, $customizedText) = Foswiki::Func::readTopic($formMeta->web(), $currentCustomization);

            push @$formRules, $customizedMeta if _checkUseGenerator($customizedMeta);
        }


        my @collectedFields = ();
        my %seenFields = ();
        my @collectedHeaders = ();
        my %seenHeaders = ();
        my @collectedPrefs = ();

        my @usedRules = ();

        foreach my $ruleMeta ( @$formRules ) {
            my $rule = $ruleMeta->text();
            my $ruleWeb = $ruleMeta->web();
            my $ruleTopic = $ruleMeta->topic();
            my $rulePrio = $ruleMeta->getPreference('FormGenerator_Priority') || 0;
            my $ruleOrder = $ruleMeta->getPreference('FormGenerator_Order') || 0;

            push @usedRules, "$ruleWeb.$ruleTopic";

            if($ruleMeta->getPreference('FormGenerator_ExpandMacros')) {
                my $ruleWebTopic = "$ruleWeb/$ruleTopic";
                if($ruleWeb eq $Foswiki::cfg{SystemWebName} || grep { $_ eq $ruleWebTopic } @{$Foswiki::cfg{Extensions}{FormGeneratorPlugin}{allowExpand}}) {
                    Foswiki::Func::pushTopicContext($web, $formTopic);
                    $rule = $ruleMeta->expandMacros($rule);
                    Foswiki::Func::popTopicContext();
                } else {
                    $errors .= '%MAKETEXT{"Not allowed to expand [_1]!" args="'.$ruleWebTopic.'"}%'."\n\n";
                    $rule = '';
                }
            }
            $rule =~ s#\@DELAY#\%#g;
            $rule =~ s#\@QUOT#"#g;
            $rule =~ s#\@NOP##g;

            my ($columns, $fields, $prefs) = _parseFormDefinition($rule);
            while (my ($k, $v) = each(%$prefs)) {
                push @collectedPrefs, [$rulePrio, $ruleTopic, $ruleOrder, $k, $v];
            }

            # see where we need to put stuff

            for(my $i = 0; $i < scalar @$columns; $i++) {
                my $column = $columns->[$i];
                if ($column && !exists $seenHeaders{$column}) {
                    $seenHeaders{$column} = scalar @collectedHeaders;
                    push @collectedHeaders, $column || '';
                }
            }

            push(@collectedFields, map {[$rulePrio, $ruleTopic, $ruleOrder, $_->{name}, $_]} @$fields);
        }

        # build the new form

        # header
        my $formText = '| ' . join(' | ', map { "*$_*" } @collectedHeaders) . " |\n";

        # form
        foreach my $field ( _prioritizedUnique(\@collectedFields) ) {
            next if $field->[4]{type} eq '@REMOVE';
            my @outputFields;
            for my $header (@collectedHeaders) {
                my $value = $field->[4]{$header};
                push @outputFields, defined $value ? $value : '';
            }

            # build the string
            $formText .= '| ' . join(' | ', @outputFields) . " |\n";
        }

        # extra stuff
        if (scalar @collectedPrefs) {
            $formText .= "\n";
            for my $pref ( sort { $a->[3] cmp $b->[3] } _prioritizedUnique(\@collectedPrefs) ) {
                next if $pref->[4] eq '@REMOVE';
                $formText .= "   * Set $pref->[3] = $pref->[4]\n";
            }
        }

        # footer / view-template / mark as generated / ACLs / remember rules
        $formText = '%RED%%MAKETEXT{"This form has been created by FormGeneratorPlugin, <b>do not modify</b>!"}%%ENDCOLOR%'."\n\n$formText";
        $formText .= "\n\n\%RED\%<b>ERRORS:</b>\n\n$errors\%ENDCOLOR\%" if $errors;
        $formText .= "\n<!--\n   * Local VIEW_TEMPLATE = FormGeneratorGeneratedFormView\n-->\n";
        $formMeta->putKeyed('PREFERENCE', {type => 'Set', name => 'FormGenerator_AUTOGENERATED', title => 'FormGenerator_AUTOGENERATED' , value => 1} );
        $formMeta->putKeyed('PREFERENCE', {type => 'Set', name => 'WORKFLOW', title => 'WORKFLOW' , value => ''} );
        $formMeta->putKeyed('PREFERENCE', {type => 'Set', name => 'ALLOWTOPICCHANGE', title => 'ALLOWTOPICCHANGE' , value => 'AdminGroup'} );
        $formMeta->putKeyed('PREFERENCE', {type => 'Set', name => 'DISPLAYCOMMENTS', title => 'DISPLAYCOMMENTS' , value => 'off'} );
        $formMeta->putKeyed('PREFERENCE', {type => 'Set', name => 'UsedRules', title => 'UsedRules', value => join(',', @usedRules)});

        if($oldText ne $formText) { # TODO: we will not notice, when preferences changed, however this is unlikely to happen without text changes
            $formMeta->text($formText);
            $formMeta->save(dontlog => 1, minor => 1);
        }
    }
}

# Sort array with arrayrefs by position, respecting priority and remove duplicates
#    * duplicate with highest priority wins.
#    * lower position means lower index in array
#    * a string will be used as tie-breaker
#    * all other things equal, the original ordering will be preserved
#    * each entry has the following structure
#       [ $priority, $name(tie-breaker), $order, $yourData, $yourOtherData ]
#
# Parameters:
#    * in (ARRAY of HASHREFs): array to be sorted
#
# Returns:
#    * sorted array
sub _prioritizedUnique {
    my ($in) = @_;
    my (@values, @result);
    for (my $i = 0; $i < scalar @$in; $i++) {
        push @values, [ @{$in->[$i]}, $i ];
    }
    for my $v (sort { $a->[0] <=> $b->[0] or $a->[1] cmp $b->[1] or $a->[5] <=> $b->[5] } @values) {
        @result = grep { $_->[3] ne $v->[3] } @result;
        push @result, $v;
    }
    return sort { $a->[2] <=> $b->[2] or $a->[1] cmp $b->[1] or $a->[5] <=> $b->[5] } @result;
}

sub _deepCopy {
    return from_json(to_json($_[0]));
}

sub _parseFormDefinition {
    my ($text) = @_;
    my $prefs;

    # trash anything before the table starts
    $text =~ s#^\s*[^|].*##g;

    ($text, $prefs) = split(/\n\n/, $text, 2);

    my @lines = split(/\n/, $text);
    my @columns = grep /./, map { lc s/^\*|\*$//gr } split(/\s*\|\s*/, shift @lines);
    @columns = map { s/^tooltip(\s*message)?/description/r } @columns;
    my @fields;
    for my $l (@lines) {
        $l =~ s/^\s*\|\s*//;
        $l =~ s/[|\s]*$//;
        my @values = split(/\s*\|\s*/, $l);
        my %fieldHash;
        for (my $i = 0; $i < @values; $i++) {
            $fieldHash{$columns[$i]} = $values[$i];
        }
        push @fields, \%fieldHash;
    }

    $prefs = '' unless defined $prefs;
    $prefs = { map { grep \&defined, @{[ m/^(?:   |\t)+\*\s*Set\s+(\w+)\s*=\s*(.*)$/ ]} } split(/\n/, $prefs) };

    (\@columns, \@fields, $prefs);
}

sub maintenanceHandler {
    # TODO: check if there are unindexed managers
    # TODO: check if there are managers without forms
    Foswiki::Plugins::MaintenancePlugin::registerCheck("FormGeneratorPlugin:unmanagedForms", {
        name => "Unmanaged forms with form managers",
        description => "Check if there are managers for forms, that have not been generated by the plugin.",
        check => sub {
            my $managers = _getAllManagers();
            my @forms = ();
            foreach my $manager ( @$managers ) {
                my ($web, $managerTopic) = Foswiki::Func::normalizeWebTopicName(undef, $manager);
                my $formTopic = $managerTopic;
                $formTopic =~ s#Manager$##;
                next unless Foswiki::Func::topicExists($web, $formTopic);
                my ($formMeta) = Foswiki::Func::readTopic($web, $formTopic);
                push @forms, "$web.$formTopic" unless $formMeta->get('PREFERENCE', 'FormGenerator_AUTOGENERATED');
            }
            if(scalar @forms) {
                return {
                    result => 1,
                    priority => $Foswiki::Plugins::MaintenancePlugin::WARN,
                    solution => "Please put customizations from ".join(', ', map { "[[$_]]" } @forms)." into !ExtraFields and delete the old form."
                }
            } else {
                return { result => 0 };
            }
        }
    });
}

1;

__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Copyright (C) 2008-2014 Foswiki Contributors. Foswiki Contributors
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
