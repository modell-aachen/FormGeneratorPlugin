jQuery(function($) {
    var log = function() {
        if(window.console) console.log.apply(this, arguments);
        if(window.console.trace) console.trace();
    }

    var rules, removedRules, rulesHeader, appControlledRules;
    var prefs, removedPrefs, prefsHeader, appControlledPrefs;

    // get and parse json
    { // scope
        var rulesArray, prefsArray;
        var json;
        try {
            json = $('.rulesJson pre').html();
            rulesArray = window.JSON.parse(json);
            json = $('.rulesRemovedJson pre').html();
            removedRules = window.JSON.parse(json);
            json = $('.rulesHeadersJson pre').html();
            rulesHeader = window.JSON.parse(json);
            json = $('.rulesAppControlledJson pre').html();
            appControlledRules = window.JSON.parse(json);
            json = $('.prefsJson pre').html();
            prefsArray = window.JSON.parse(json);
            json = $('.prefsRemovedJson pre').html();
            removedPrefs = window.JSON.parse(json);
            json = $('.prefsHeadersJson pre').html();
            prefsHeader = window.JSON.parse(json);
            json = $('.prefsAppControlledJson pre').html();
            appControlledPrefs = window.JSON.parse(json);
        } catch (e) {
            log(e);
        }

        // turn into easy to handle object
        // { 'ruleName': { 'name': 'ruleName', 'generator': 'MyGenerator' ... }}
        var objectify = function(header, array) {
            var object = {};
            var hNameColumn = header.indexOf('name');
            if(hNameColumn === -1) {
                log('Could not find "name" in headers', header);
                return {};
            }
            if(!(array && array.length)) {
                log('Invalid array', array);
                return {};
            }
            var i;
            $.each(array, function(idx, item) {
                var name = item[hNameColumn];
                object[name] = {};
                for(i = 0; i < item.length; i++) {
                    object[name][header[i]] = item[i];
                }
            });
            return object;
        };

        rules = objectify(rulesHeader, rulesArray);
        prefs = objectify(prefsHeader, prefsArray);
    }

    // helpers:
    var time = new Date().getTime();
    var hrefAuto = foswiki.getScriptUrl('edit') + '/' + foswiki.getPreference('WEB') + '/' + foswiki.getPreference('TOPIC') + 'ExtraFieldsAUTOINC1?';
    var webtopic = encodeURIComponent(foswiki.getPreference('WEB') + '.' + foswiki.getPreference('TOPIC'));
    var templatetopic = foswiki.getPreference('SYSTEMWEB') + '/FormGeneratorExtraFieldsTemplate'; // XXX not configurable
    var template = 'FormGeneratorExtraFieldsEdit';
    var $table = $('.foswikiTopic table.foswikiTable:first');
    var $thead = $table.find('tr:first');
    var $settings = $('.foswikiTopic ul:first');
    // recreate header line from rendered form table
    var headerText = "|" + $.map($thead.children(), function(item) {return ' ' + $(item).text() + ' ';}).join('|')  + "|";
    // turns an object into a parameter string for hrefs
    var toParam = function(options) {
        var parts = [];
        $.each(options, function(name, value) {
            parts.push(name + '=' + value);
        });
        return parts.join(';');
    };
    // default parameters to most edit links
    var editDefaultParams = '?' + toParam({
        nowysiwyg: 1,
        redirectto: webtopic,
        modactransientparam: 'redirectto',
        t: time
    })

    // parse form
    { // scope
        var $tr = $table.find('tr:not(:first)');

        // Regex to split a (TML) form definition line on the 'attribute' column.
        // Will be used to insert @REPLACE when customizing.
        var attribReg = new RegExp("^(\\s*\\|" + $.map($thead.children(), function(item) {
            if($(item).text().trim() == 'attributes') {
                // start second capture group here
                return ')\\s?([^|]*';
            } else {
                return '[^|]*';
            }
        }).join('\\|')  + "\\|.*)");

        // add extra columns (to header)
        $('<th></th>').text(jsi18n.get('FormGenerator', 'status')).prependTo($thead);
        $('<th></th>').text(jsi18n.get('FormGenerator', 'actions')).appendTo($thead);

        var nameColumn = -1;
        $.each($thead.children(), function(idx, item) {
            if($(item).text().trim() === 'name') nameColumn = idx;
        });
        if(nameColumn === -1) {
            log('Could not find "name" in form-table header');
            return;
        }

        // add status/actions to each row of the table
        $tr.each(function() {
            var $this = $(this);

            var $status = $('<td></td>').prependTo($this);
            var $actions = $('<td></td>').appendTo($this);

            var name = $this.find('td:nth(' + nameColumn +')').text().trim();
            if(!name) {
                log('Column has no name: ' + $this.html());
                return;
            }
            var rule = rules[name];
            if(!rule) {
                log('Could not find rule for ' + name);
                return;
            }

            if(/\.FormGenerator_/.test(rule.generator)) { // TODO handle custom FormGenerator topics

                var options = {
                    Priority: (rule.priority + 1),
                    Order: rule.order || 0,
                    name: rule.name,
                    templatetopic: templatetopic,
                    nowysiwyg: 1,
                    template: template,
                    redirectto: webtopic,
                    modactransientparam: 'redirectto',
                    t: time
                };

                // customize link
                options.text = encodeURIComponent(headerText + "\n" + rule.text.replace(attribReg, '$1 @REPLACE $2'));
                $('<div></div>').addClass('FormGeneratorStatus notmodified').text(jsi18n.get('FormGenerator', 'standard')).appendTo($status);
                $('<a></a>').addClass('FormGeneratorAction').text(jsi18n.get('FormGenerator', 'customize')).attr('href', hrefAuto + toParam(options)).appendTo($actions);

                // remove link
                options.text = encodeURIComponent(headerText + "\n" + headerText.replace(/([a-z]*)/g, '"$1"').replace('"name"', rule.name).replace('"type"', '@REMOVE').replace(/"[a-z]*"/g, ''));
                $('<a></a>').addClass('FormGeneratorAction').text(jsi18n.get('FormGenerator', 'remove')).attr('href', hrefAuto + toParam(options)).appendTo($actions).before('<br />');
            } else if(/ExtraFields\d+$/.test(rule.generator)) {
                var cclass = (appControlledRules[rule.name] ? 'customized' : 'custom');
                $('<div></div>').addClass('FormGeneratorStatus').addClass(cclass).text(jsi18n.get('FormGenerator', cclass)).appendTo($status);
                var editHref = foswiki.getScriptUrl('edit') + '/' + rule.generator.replace('.', '/') + editDefaultParams;
                $('<a></a>').addClass('FormGeneratorAction').text(jsi18n.get('FormGenerator', 'edit generator')).attr('href', editHref).appendTo($actions);
            } else {
                $('<div></div>').addClass('FormGenerator').text(jsi18n.get('FormGenerator', 'unknown')).appendTo($status);
                log('Can not evaluate ' + rule.generator);
            }

        });

        // removed fields

        if(removedRules.length) {
            var $trTemplate = $('<tr></tr>');
            $thead.find('th').each(function() {
                $('<td></td>').addClass('FormGeneratorExtra_' + $(this).text().trim()).appendTo($trTemplate);
            });
            // these are changed by jsi18n and thus are unreliable as class:
            $trTemplate.find('td:first').addClass('FormGeneratorExtra_status');
            $trTemplate.find('td:last').addClass('FormGeneratorExtra_actions');

            var $sep = $trTemplate.clone();
            $sep.addClass('FormGeneratorSep').appendTo($table);

            var hIdx = {}; // map 'header name' -> 'position in the array'
            $.each(rulesHeader, function(idx, item) {
                hIdx[item] = idx;
            });

            $.each(removedRules, function(idx, item) {
                var $tr = $trTemplate.clone();
                $tr.addClass('foswikiTableRowdataBg' + idx % 2);
                $tr.find('.FormGeneratorExtra_status').append($('<div></div>').text(jsi18n.get('FormGenerator', 'removed')).addClass('FormGeneratorStatus removed'));
                $tr.find('.FormGeneratorExtra_name').append($('<span></span>').text(item[hIdx.name]).addClass('FormGeneratorRemoved'));
                $tr.find('.FormGeneratorExtra_generator').append($('<span></span>').text(item[hIdx.generator]));
                var editHref = foswiki.getScriptUrl('edit') + '/' + item[hIdx.generator].replace('.', '/') + '?' + editDefaultParams;
                var $edit = $('<a></a>').addClass('FormGeneratorAction').text(jsi18n.get('FormGenerator', 'edit generator')).attr('href', editHref);
                $tr.find('.FormGeneratorExtra_actions').append($edit);

                $table.append($tr);
            });
        }
    }

    // settings
    { // scope
        // TODO: turn this into something less offending to the eye

        // parse prefs

        var $sets = $settings.find('li').each(function() {
            var $this = $(this);

            var name = /^\s?Set\s+([^=\s]+)\s*=/.exec($this.text());
            if(!name) return;
            name = name[1];

            var rule = prefs[name];
            if(!rule) {
                log('No rule for pref ' + name);
                return;
            }
            if(/\.FormGenerator_/.test(rule.generator)) { // TODO handle custom FormGenerator topics
                if(appControlledPrefs[name]) {
                    $this.append('&nbsp;').append($('<span></span>').addClass('FormGeneratorStatus notmodified').text(jsi18n.get('FormGenerator', 'standard')));

                    var options = {
                        Priority: (rule.priority + 1),
                        Order: rule.order || 0,
                        name: rule.name,
                        templatetopic: templatetopic,
                        nowysiwyg: 1,
                        template: template,
                        redirectto: webtopic,
                        modactransientparam: 'redirectto',
                        t: time
                    };

                    // customize link
                    options.text = encodeURIComponent(headerText + "\n\n" + "   * Set " + rule.text);
                    $this.append('&nbsp;').append($('<a></a>').addClass('FormGeneratorAction').text(jsi18n.get('FormGenerator', 'customize')).attr('href', hrefAuto + toParam(options)));

                    // remove link
                    options.text = encodeURIComponent(headerText + "\n\n" + "   * Set " + rule.name + " = @REMOVE");
                    $this.append('&nbsp;').append($('<a></a>').addClass('FormGeneratorAction').text(jsi18n.get('FormGenerator', 'remove')).attr('href', hrefAuto + toParam(options)));
                }
            } else if(/ExtraFields\d+$/.test(rule.generator)) {
                var cclass = (appControlledPrefs[rule.name] ? 'customized' : 'custom');
                $this.append('&nbsp;').append($('<span></span>').addClass('FormGeneratorStatus').addClass(cclass).text(jsi18n.get('FormGenerator', cclass)));
                var editHref = foswiki.getScriptUrl('edit') + '/' + rule.generator.replace('.', '/') + '?' + editDefaultParams;
                $this.append('&nbsp;').append($('<a></a>').addClass('FormGeneratorAction').text(jsi18n.get('FormGenerator', 'edit generator')).attr('href', editHref));
            } else {
                $('<span></span>').addClass('FormGenerator').text(jsi18n.get('FormGenerator', 'unknown')).appendTo($this);
                log('Can not evaluate ' + rule.generator);
            }
        });

        // removed pres

        if(removedPrefs.length) {
            var $liTemplate = $('<li></li>');

            var $sep = $liTemplate.clone();
            $sep.addClass('FormGeneratorSep').appendTo($settings);

            var hIdx = {}; // map 'header name' -> 'position in the array'
            $.each(prefsHeader, function(idx, item) {
                hIdx[item] = idx;
            });

            $.each(removedPrefs, function(idx, item) {
                var $li = $liTemplate.clone();
                $li.append($('<span></span>').text(item[hIdx.name]).addClass('FormGeneratorRemoved'));
                $li.append('&nbsp;').append($('<span></span>').text(jsi18n.get('FormGenerator', 'removed')).addClass('FormGeneratorStatus removed'));
                var editHref = foswiki.getScriptUrl('edit') + '/' + item[hIdx.generator].replace('.', '/') + '?' + editDefaultParams;
                var $edit = $('<a></a>').addClass('FormGeneratorAction').text(jsi18n.get('FormGenerator', 'edit generator')).attr('href', editHref);
                $li.append('&nbsp;').append($edit);

                $settings.append($li);
            });
        }
    }


});
