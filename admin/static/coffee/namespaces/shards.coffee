
# Helper stuff
Handlebars.registerPartial 'shard_name_td', $('#shard_name_td-partial').html()

# Namespace view
module 'NamespaceView', ->
    # Hardcoded!
    MAX_SHARD_COUNT = 32

    # All of our rendering code needs a view of available shards
    compute_renderable_shards_array = (namespace_uuid, shards) ->
        ret = []
        for i in [0...shards.length]
            primary_uuid = DataUtils.get_shard_primary_uuid namespace_uuid, shards[i]
            secondary_uuids = DataUtils.get_shard_secondary_uuids namespace_uuid, shards[i]
            ret.push
                name: human_readable_shard shards[i]
                shard: shards[i]
                shard_stats:
                    rows_approx: namespaces.get(namespace_uuid).compute_shard_rows_approximation(shards[i])
                notlast: i != shards.length - 1
                index: i
                primary:
                    uuid: primary_uuid
                    # primary_uuid may be null when a new shard hasn't hit the server yet
                    name: if primary_uuid then machines.get(primary_uuid).get('name') else null
                    status: if primary_uuid then DataUtils.get_machine_reachability(primary_uuid) else null
                    backfill_progress: if primary_uuid then DataUtils.get_backfill_progress(namespace_uuid, shards[i], primary_uuid) else null
                secondaries: _.map(secondary_uuids, (machine_uuids, datacenter_uuid) ->
                    datacenter_uuid: datacenter_uuid
                    datacenter_name: datacenters.get(datacenter_uuid).get('name')
                    machines: _.map(machine_uuids, (machine_uuid) ->
                        uuid: machine_uuid
                        name: machines.get(machine_uuid).get('name')
                        status: DataUtils.get_machine_reachability(machine_uuid)
                        backfill_progress: DataUtils.get_backfill_progress(namespace_uuid, shards[i], machine_uuid)
                        )
                    )
        return ret

    # Shards view
    class @Shards extends Backbone.View
        className: 'namespace-shards'
        template: Handlebars.compile $('#namespace_view-sharding-template').html()

        initialize: ->
            log_initial '(initializing) namespace view: shards'
            # Basic setup
            @model.on 'all', @render
            directory.on 'all', @render
            progress_list.on 'all', @render
            @shards = []

        bind_edit_machines: (shard) ->
            # Master assignments
            @.$('#assign_master_' + shard.index).click (e) =>
                e.preventDefault()
                modal = new NamespaceView.EditMasterMachineModal @model, shard.shard
                modal.render()

            # Fucking JS closures
            bind_shard = (shard, secondary) =>
                @.$('#assign_machines_' + shard.index + '_' + secondary.datacenter_uuid).click (e) =>
                    e.preventDefault()
                    modal = new NamespaceView.EditReplicaMachinesModal @model, _.extend secondary,
                        name: shard.name
                        shard: shard.shard
                    modal.render()

            for secondary in shard.secondaries
                bind_shard shard, secondary

        render: =>
            log_render '(rendering) namespace view: shards'

            shards_array = compute_renderable_shards_array(@model.get('id'), @model.get('shards'))
            @.$el.html @template
                shards: shards_array
                namespace_uuid: @model.get('id')

            # Bind events to 'assign machine' links
            for shard in shards_array
                @bind_edit_machines(shard)

            return @

    # A view for modifying the sharding plan.
    class @ModifyShards extends Backbone.View
        template: Handlebars.compile $('#modify_shards-template').html()
        alert_tmpl: Handlebars.compile $('#modify_shards-alert-template').html()
        class: 'modify-shards'
        events:
            'click #suggest_shards_btn': 'suggest_shards'
            'click #cancel_shards_suggester_btn': 'cancel_shards_suggester_btn'
            'click .btn-compute-shards-suggestion': 'compute_shards_suggestion'
            'click .btn-reset': 'reset_shards'
            'click .btn-primary': 'on_submit'

        initialize: (namespace_id, shard_set) ->
            log_initial '(initializing) view: ModifyShards'
            @namespace_id = namespace_id
            @namespace = namespaces.get(@namespace_id)
            shard_set = @namespace.get('shards')

            # Keep an unmodified copy of the shard boundaries with which we compare against when reviewing the changes.
            @original_shard_set = _.map(shard_set, _.identity)
            @shard_set = _.map(shard_set, _.identity)

            # Shard suggester business
            @suggest_shards_view = false

            # We should rerender on key distro updates
            @namespace.on 'all', @render

            super

        reset_shards: (e) ->
            e.preventDefault()
            @shard_set = _.map(@original_shard_set, _.identity)
            @render()

        reset_button_enable: ->
            @.$('.btn-reset').button('reset')

        reset_button_disable: ->
            @.$('.btn-reset').button('loading')

        suggest_shards: (e) =>
            e.preventDefault()
            @suggest_shards_view = true
            @render()

        user_num_shards: ''

        compute_shards_suggestion: (e) =>
            # Do the bullshit event crap
            e.preventDefault()
            @.$('.btn-compute-shards-suggestion').button('loading')

            # Make sure their input aint crazy
            @desired_shards = parseInt(form_data_as_object($('form', @.el)).num_shards)
            if isNaN(@desired_shards)
                @error_msg = "The number of shards must be an integer."
                @render()
                return
            if @desired_shards < 1 or @desired_shards > MAX_SHARD_COUNT
                @error_msg = "The number of shards must be beteen 1 and " + MAX_SHARD_COUNT + "."
                @render()
                return

            # grab the data
            data = @namespace.get('key_distr')
            distr_keys = @namespace.sorted_key_distr_keys(data)
            total_rows = _.reduce distr_keys, ((agg, key) => return agg + data[key]), 0
            rows_per_shard = total_rows / @desired_shards

            # Make sure there is enough data to actually suggest stuff
            if distr_keys.length < 2
                @error_msg = "There isn't enough data in the database to suggest shards."
                @render()
                return

            # Phew. Go through the keys now and compute the bitch ass split points.
            current_shard_count = 0
            split_points = [""]
            no_more_splits = false
            for key in distr_keys
                # Let's not overdo it :-D
                if split_points.length >= @desired_shards
                    no_more_splits = true
                current_shard_count += data[key]
                if current_shard_count >= rows_per_shard and not no_more_splits
                    # Hellz yeah ho, we got our split point
                    split_points.push(key)
                    current_shard_count = 0
            split_points.push(null)

            # convert split points into whatever bitch ass format we're using here
            _shard_set = []
            for splitIndex in [0..(split_points.length - 2)]
                _shard_set.push(JSON.stringify([split_points[splitIndex], split_points[splitIndex + 1]]))

            # See if we have enough shards
            if _shard_set.length < @desired_shards
                @error_msg = "There is only enough data to suggest " + _shard_set.length + " shards."
                @render()
                return
            @shard_set = _shard_set

            # All right, we be done, boi. Put those
            # motherfuckers into the dialog, reset the buttons
            # or whateva, and hop on into the sunlight.
            @.$('.btn-compute-shards-suggestion').button('reset')
            @render()

        cancel_shards_suggester_btn: (e) =>
            e.preventDefault()
            @suggest_shards_view = false
            @render()

        insert_splitpoint: (index, splitpoint) =>
            if (0 <= index || index < @shard_set.length)
                json_repr = $.parseJSON(@shard_set[index])
                if (splitpoint <= json_repr[0] || (splitpoint >= json_repr[1] && json_repr[1] != null))
                    throw "Error invalid splitpoint"

                @shard_set.splice(index, 1, JSON.stringify([json_repr[0], splitpoint]), JSON.stringify([splitpoint, json_repr[1]]))
                @render()
            else
                # TODO handle error

        merge_shard: (index) =>
            if (index < 0 || index + 1 >= @shard_set.length)
                throw "Error invalid index"

            newshard = JSON.stringify([$.parseJSON(@shard_set[index])[0], $.parseJSON(@shard_set[index+1])[1]])
            @shard_set.splice(index, 2, newshard)
            @render()

        render: =>
            @user_num_shards = @.$('.num_shards').val()

            log_render '(rendering) ModifyShards'

            # TODO render "touched" shards (that have been split or merged within this view) a bit differently
            user_made_changes = JSON.stringify(@original_shard_set).replace(/\s/g, '') isnt JSON.stringify(@shard_set).replace(/\s/g, '')
            json =
                namespace: @namespace.toJSON()
                shards: compute_renderable_shards_array(@namespace.get('id'), @shard_set)
                suggest_shards_view: @suggest_shards_view
                current_shards_count: @original_shard_set.length
                max_shard_count: MAX_SHARD_COUNT
                new_shard_count: if @desired_shards? then @desired_shards else @shard_set.length
                unsaved_settings: user_made_changes
                error_msg: @error_msg
            @error_msg = null
            @.$el.html(@template json)

            shard_views = _.map(compute_renderable_shards_array(@namespace.get('id'), @shard_set), (shard) => new NamespaceView.ModifySingleShard @namespace, shard, @)
            @.$('.shards tbody').append view.render().el for view in shard_views
            @.$('.num_shards').val(@user_num_shards)
            # Control the suggest button
            @.$('.btn-compute-shards-suggestion').button()

            # Control the reset button, boiii
            if user_made_changes
                @reset_button_enable()
            else
                @reset_button_disable()

            return @

        on_submit: (e) =>
            e.preventDefault()
            @.$('.btn-primary').button('loading')
            formdata = form_data_as_object($('form', @el))

            empty_master_pin = {}
            empty_master_pin[JSON.stringify(["", null])] = null
            empty_replica_pins = {}
            empty_replica_pins[JSON.stringify(["", null])] = []
            json =
                shards: @shard_set
                primary_pinnings: empty_master_pin
                secondary_pinnings: empty_replica_pins
            # TODO detect when there are no changes.
            $.ajax
                processData: false
                url: "/ajax/#{@namespace.attributes.protocol}_namespaces/#{@namespace.id}"
                type: 'POST'
                contentType: 'application/json'
                data: JSON.stringify(json)
                success: @on_success

        on_success: (response) =>
            @.$('.btn-primary').button('reset')
            namespaces.get(@namespace.id).set(response)
            window.app.navigate('/#namespaces/' + @namespace.get('id'), {trigger: true})
            $('#user-alert-space').append(@alert_tmpl({}))

    # A view for modifying a specific shard
    class @ModifySingleShard extends Backbone.View
        template: Handlebars.compile $('#modify_shards-view_shard-template').html()
        editable_tmpl: Handlebars.compile $('#modify_shards-edit_shard-template').html()

        tagName: 'tr'
        class: 'shard'

        events: ->
            'click .split': 'split'
            'click .commit_split': 'commit_split'
            'click .cancel_split': 'cancel_split'
            'click .merge': 'merge'
            'click .commit_merge': 'commit_merge'
            'click .cancel_merge': 'cancel_merge'

        initialize: (namespace, shard, parent_modal) ->
            @namespace = namespace
            @shard = shard
            @parent = parent_modal

        render: ->
            @.$el.html @template
                shard: @shard

            return @

        split: (e) ->
            shard_index = $(e.target).data 'index'
            log_action "split button clicked with index #{shard_index}"

            @.$el.html @editable_tmpl
                splitting: true
                shard: @shard

            e.preventDefault()

        cancel_split: (e) ->
            @render()
            e.preventDefault()

        commit_split: (e) ->
            splitpoint = $('input[name=splitpoint]', @el).val()
            # TODO validate splitpoint
            e.preventDefault()

            @parent.insert_splitpoint(@shard.index, splitpoint);

        merge: (e) =>
            @.$el.html @editable_tmpl
                merging: true
                shard: @shard
            e.preventDefault()

        cancel_merge: (e) =>
            @render()
            e.preventDefault()

        commit_merge: (e) =>
            @parent.merge_shard(@shard.index)
            e.preventDefault()

