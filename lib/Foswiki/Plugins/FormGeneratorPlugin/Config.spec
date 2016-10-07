# ---+ Extensions
# ---++ FormGeneratorPlugin

# **PERL**
# Array of generators (outside of System) that are allowed to expand macros. Enter full web and topic with slashes as separators. Eg. <pre>['MyWeb/FormGenerator_MyGenerator', 'MyWeb/SubWeb/FormGenerator_MyOtherGenerator']</pre>
$Foswiki::cfg{Extensions}{FormGeneratorPlugin}{allowExpand} = [];

# **STRING**
# TML condition that must expand to =1= or =on= on any generator. Leave empty to always activate generators.
# If this condition is not met, you are still allowed to _create_ that generator, however it will not be used.
$Foswiki::cfg{Extensions}{FormGeneratorPlugin}{Condition} = '%GETWORKFLOWROW{approved}%';

# **STRING**
# This group is used as %<nop>KeyUserGroup% in <em>AllowExtraFields</em> and defaults to <em>KeyUserGroup</em>
$Foswiki::cfg{Extensions}{FormGeneratorPlugin}{KeyUserGroup} = 'KeyUserGroup';

# **STRING**
# Groups and people, that are allowed to create ExtraFields topics.
# Defaults to <pre>%<nop>IF{"'%<nop>WORKFLOWMETA%'=''" then="%<nop>%KeyUserGroup%" else="LOGGEDIN"}%</pre>
$Foswiki::cfg{Extensions}{FormGeneratorPlugin}{AllowExtraFields} = '';

# **PERL**
# Array of webs, where FormGenerators may be created.
$Foswiki::cfg{Extensions}{FormGeneratorPlugin}{FormGeneratorWebs} = ["System", "Custom"];
