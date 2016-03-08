###
 SageMathCloud: A collaborative web-based interface to Sage, Python, LaTeX and the Terminal.

    Copyright (C) 2014, 2015, 2016, William Stein

Jupyter Notebook Synchronization

There are multiple representations of the notebook.

   - @doc      = syncstring version of the notebook (uses SMC sync functionality)
   - @nb       = the visible view stored in the browser DOM
   - @filename = the .ipynb file on disk

In addition, every other browser opened viewing the notebook has it's own @doc and @nb, and
there is a single upstream copy of @doc in the local_hub daemon.

The user edits @nb.  Periodically we check to see if any changes were made (@nb.dirty) and
if so, we copy the state of @nb to @doc's live.

When @doc changes do to some other user changing something, we compute a diff that tranforms
the live notebook from its current state to the state that matches the new version of @doc.
See the function set_nb below.  Incidentally, I came up with this approach from scratch after
trying a lot of ideas, though in hindsite it's exactly the same as what React.js does (though
I didn't know about React.js at the time).
###

{EventEmitter}       = require('events')

async                = require('async')
misc                 = require('smc-util/misc')
{defaults, required} = misc
{dmp}                = require('smc-util/syncstring')
{salvus_client}      = require('./salvus_client')
{redux}              = require('./smc-react')
syncdoc              = require('./syncdoc')
{synchronized_db}    = require('./syncdb')
sha1                 = require('sha1')
misc_page            = require('./misc_page')

templates            = $(".smc-jupyter-templates")
editor_templates     = $("#salvus-editor-templates")

exports.IPYTHON_SYNCFILE_EXTENSION = IPYTHON_SYNCFILE_EXTENSION = ".jupyter-sync"

exports.jupyter_nbviewer = (editor, filename, content, opts) ->
    X = new JupyterNBViewer(editor, filename, content, opts)
    element = X.element
    element.data('jupyter_nbviewer', X)
    return element

class JupyterNBViewer
    constructor: (@editor, @filename, @content, opts) ->
        @element = templates.find(".smc-jupyter-nbviewer").clone()
        @ipynb_filename = @filename.slice(0,@filename.length-4) + 'ipynb'
        @ipynb_html_src = "/#{@editor.project_id}/raw/#{@filename}"
        @init_buttons()

    show: () =>
        if not @iframe?
            @iframe = @element.find(".smc-jupyter-nbviewer-content").find('iframe')
            # We do this, since otherwise just loading the iframe using
            #      @iframe.contents().find('html').html(@content)
            # messes up the parent html page, e.g., foo.modal() is gone.
            # setting the content this way, works in Chrome, but not FF
            #@iframe.contents().find('body').first().html(@content)
            # FIXME although really bad overhead, this is a quick fix for FF
            # callback, run after "load" event below this line
            @iframe.load ->
                @iframe.contents().find("body").on("click mousemove keydown focusin", smc.client.reset_idle)
            @iframe.attr('src', @ipynb_html_src)

        @element.css(top:@editor.editor_top_position())
        @element.maxheight(offset:18)
        @element.find(".smc-jupyter-nbviewer-content").maxheight(offset:18)
        @iframe.maxheight(offset:18)

    init_buttons: () =>
        @element.find('a[href=#copy]').click () =>
            @editor.project_page.display_tab('project-file-listing')
            actions = redux.getProjectActions(@editor.project_id)
            actions.set_all_files_unchecked()
            actions.set_file_checked(@ipynb_filename, true)
            actions.set_file_action('copy')
            return false

        @element.find('a[href=#download]').click () =>
            @editor.project_page.display_tab('project-file-listing')
            actions = redux.getProjectActions(@editor.project_id)
            actions.set_all_files_unchecked()
            actions.set_file_checked(@ipynb_filename, true)
            actions.set_file_action('download')
            return false

# Download a remote URL, possibly retrying repeatedly with exponential backoff
# on the timeout.
# If the downlaod URL contains bad_string (default: 'ECONNREFUSED'), also retry.
get_with_retry = (opts) ->
    opts = defaults opts,
        url           : required
        initial_timeout : 5000
        max_timeout     : 20000     # once delay hits this, give up
        factor        : 1.1     # for exponential backoff
        bad_string    : 'ECONNREFUSED'
        cb            : required  # cb(err, data)  # data = content of that url
    timeout = opts.initial_timeout
    delay   = 50
    f = () =>
        if timeout >= opts.max_timeout  # too many attempts
            opts.cb("unable to connect to remote server")
            return
        $.ajax(
            url     : opts.url
            timeout : timeout
            success : (data) ->
                if data.indexOf(opts.bad_string) != -1
                    timeout *= opts.factor
                    setTimeout(f, delay)
                else
                    opts.cb(false, data)
        ).fail(() ->
            timeout *= opts.factor
            delay   *= opts.factor
            setTimeout(f, delay)
        )

    f()

# Embedded editor for editing IPython notebooks.  Enhanced with sync and integrated into the
# overall cloud look.

exports.jupyter_notebook = (editor, filename, opts) ->
    return (new JupyterNotebook2(editor, filename, opts)).element

class JupyterNotebook
    dbg: (f, m...) =>
        #console.log("JupyterNotebook.#{f}:#{misc.to_json(m)}")
        return salvus_client.dbg("JupyterNotebook.#{f}:")(misc.to_json(m))

    constructor: (@editor, @filename, opts={}) ->
        opts = @opts = defaults opts,
            sync_interval   : 2000
            cursor_interval : 2000
            read_only       : false
            mode            : undefined   # ignored
        window.s = @
        @element = templates.find(".smc-jupyter-notebook").clone()
        @_other_cursor_timeout_s = 30  # only show active other cursors for this long

        @_users = smc.redux.getStore('users')

        if @opts.read_only
            @readonly = true
            @element.find(".smc-jupyter-notebook-buttons").remove()

        @element.data("jupyter_notebook", @)

        # Jupyter is proxied via the following canonical URL (don't have to guess at the port):
        @server_url = "#{window.smc_base_url}/#{@editor.project_id}/port/jupyter/notebooks/"

        # special case/hack:
        if window.smc_base_url.indexOf('/port/') != -1
            # HORRIBLE hack until we can figure out how to proxy websockets through a proxy
            # (things just get too complicated)...
            console.warn("Jupyter: assuming that SMC is being run from a project installed in the ~/smc directory!!")
            i = window.smc_base_url.lastIndexOf('/')
            @server_url = "#{window.smc_base_url.slice(0,i)}/jupyter/notebooks/smc/src/data/projects/#{@editor.project_id}/"

        @_start_time = misc.walltime()
        if window.smc_base_url != ""
            # TODO: having a base_url doesn't imply necessarily that we're in a dangerous devel mode...
            # (this is just a warning).
            # The solutiion for this issue will be to set a password whenever ipython listens on localhost.
            @element.find(".smc-jupyter-notebook-danger").show()
            setTimeout( ( () => @element.find(".smc-jupyter-notebook-danger").hide() ), 3000)

        @status_element = @element.find(".smc-jupyter-notebook-status-messages")
        @init_buttons()
        s = misc.path_split(@filename)
        @path = s.head
        @file = s.tail

        if @path
            @syncdb_filename = @path + '/.' + @file + IPYTHON_SYNCFILE_EXTENSION
        else
            @syncdb_filename = '.' + @file + IPYTHON_SYNCFILE_EXTENSION

        # This is where we put the page itself
        @notebook = @element.find(".smc-jupyter-notebook-notebook")
        @con      = @element.find(".smc-jupyter-notebook-connecting")
        @setup (err) =>
            if err
                cb?(err)
            # TODO: We have to do this stupid thing because in IPython's notebook.js they don't systematically use
            # set_dirty, sometimes instead just directly setting the flag.  So there's no simple way to know exactly
            # when the notebook is dirty. (TODO: fix all this via upstream patches.)
            if not @readonly
                @_autosync_interval = setInterval(@autosync, @opts.sync_interval)
                @_cursor_interval   = setInterval(@broadcast_cursor_pos, @opts.cursor_interval)

    status: (text) =>
        if not text?
            text = ""
        else if false
            text += " (started at #{Math.round(misc.walltime(@_start_time))}s)"
        @status_element.html(text)

    # Return the last modification time of the .ipynb file on disk.
    # TODO: this has nothing to do with ipynb files -- refactor...
    get_ipynb_file_timestamp: (cb) =>
        salvus_client.exec
            project_id : @editor.project_id
            path       : @path
            command    : "stat"   # %Z below = time of last change, seconds since Epoch; use this not %Y since often users put file in place, but with old time
            args       : ['--printf', '%Z ', @file]
            timeout    : 20
            err_on_exit: false
            cb         : (err, output) =>
                if err
                    cb(err)
                else if output.stderr.indexOf('such file or directory') != -1
                    # ipynb file doesn't exist
                    cb(undefined, 0)
                else
                    cb(undefined, parseInt(output.stdout)*1000)

    setup: (cb) =>
        if @_setting_up
            cb?("already setting up")
            return  # already setting up
        @_setting_up = true
        @con.show().icon_spin(start:true)
        delete @_cursors   # Delete all the cached cursors in the DOM
        delete @nb
        delete @frame
        @_initialized = false

        async.series([
            (cb) =>
                @status("Getting last time that ipynb file was modified")
                @get_ipynb_file_timestamp (err, x) =>
                    @_ipynb_last_modified = x
                    cb(err)
            (cb) =>
                @status("Ensuring synchronization file exists")
                @editor.project_page.ensure_file_exists
                    path  : @syncdb_filename
                    alert : false
                    cb    : (err) =>
                        if err
                            # unable to create syncdoc file -- open in non-sync read-only mode.
                            @readonly = true
                        cb()
            (cb) =>
                @initialize(cb)
            (cb) =>
                if @readonly
                    @dbg("setup", "readonly")
                    # TODO -- change UI to say *READONLY*
                    @iframe.css(opacity:1)
                    @save_button.text('Readonly').addClass('disabled')
                    @show()
                    for c in @nb.get_cells()
                        c.code_mirror?.setOption('readOnly',true)
                    cb()
                else
                    @dbg("setup", "_init_doc")
                    @_init_doc(cb)
        ], (err) =>
            @con.show().icon_spin(false).hide()
            @_setting_up = false
            if err
                @save_button.addClass("disabled")
                @status("Failed to start -- #{err}")
                cb?("Unable to start Jupyter notebook server -- #{err}")
            else
                @_initialized = true
                cb?()
        )

    show_history_viewer: () =>
        path = misc.history_path(@filename)
        @dbg("show_history_viewer", path)
        @editor.project_page.open_file
            path       : path
            foreground : true

    _init_doc: (cb) =>
        if @opts.read_only
            cb()
            return

        #console.log("_init_doc: connecting to sync session")
        @status("Connecting to synchronized editing session...")
        if @doc?
            # already initialized
            @doc.sync () =>
                @set_nb_from_doc()
                @iframe.css(opacity:1)
                @show()
                cb?()
            return
        syncdoc.synchronized_string
            project_id        : @editor.project_id
            filename          : @syncdb_filename
            cb                : (err, doc) =>
                @status()
                if err
                    cb?("Unable to connect to synchronized document server -- #{err}")
                else
                    @doc = doc
                    console.log(@_ipynb_last_modified, @doc._syncstring.last_changed() - 0)
                    if @_ipynb_last_modified >= @doc._syncstring.last_changed() - 0
                        console.log("set from visible")
                        # set the syncstring from the visible notebook, just loaded from the file
                        @doc.live(@nb_to_string())
                    else
                        console.log("set from syncstring")
                        # set the visible notebook from the synchronized string
                        @set_nb_from_doc()
                    @_config_doc()
                    cb?()

    _config_doc: () =>
        if @opts.read_only
            cb()
            return
        @dbg("_config_doc")
        # todo -- should check if .ipynb file is newer... ?
        @status("Displaying Jupyter Notebook")
        @dbg("_config_doc", "DONE SETTING!")

        @iframe.css(opacity:1)
        @show()

        @doc._syncstring.on 'before-save', () =>
            if not @nb? or @_reloading
                # no point -- reinitializing the notebook frame right now...
                return
            #@dbg("about to sync with upstream")
            # We ensure that before we sync with upstream, the live
            # syncstring equals what is in the DOM.  We pass true
            # into nb_to_string, so any changes to the DOM that result
            # in new images (e.g., output of computations) will get saved
            # to the database, so that other users can eventually see them.
            @before_sync = @nb_to_string(true)
            @doc.live(@before_sync)

        @doc._syncstring.on 'before-change', () =>
            @doc.live(@nb_to_string())

        @doc.on 'sync', () =>
            # We just sync'ed with upstream.
            after_sync = @doc.live()
            if @before_sync != after_sync
                # Apply any upstream changes to the DOM.
                #console.log("sync - before='#{@before_sync}'")
                #console.log("sync - after='#{after_sync}'")
                @_last_remote_change = new Date()  # used only for stupid temporary broadcast_cursor_pos hack below.
                @set_nb_from_doc()

        @doc._syncstring.on('cursor_activity', @render_other_cursor)

        @status()

    broadcast_cursor_pos: () =>
        if not @nb? or @readonly or not @doc?
            # no point -- reloading or loading or read-only
            return
        # This is an ugly hack to ignore cursor movements resulting from remote changes.
        caused = not @_last_remote_change? or @_last_remote_change - new Date() != 0
        index = @nb.get_selected_index()
        cell  = @nb.get_cell(index)
        if not cell?
            return
        cm = cell.code_mirror
        # Get the locations of *all* cursors (and the cell index i).
        locs = ({i:index, x:c.anchor.ch, y:c.anchor.line} for c in cm.listSelections())
        s = misc.to_json(locs)
        if s != @_last_cursor_pos
            @_last_cursor_pos = s
            @doc._syncstring.set_cursor_locs(locs, caused)

    render_other_cursor: (account_id) =>
        if account_id == salvus_client.account_id
            # nothing to do -- we don't draw our own cursor via this
            return
        console.log('render_other_cursor', account_id)
        x = @doc._syncstring.get_cursors()?.get(account_id)
        if not x?
            return
        # important: must use server time to compare, not local time.
        if salvus_client.server_time() - x.get('time') <= @_other_cursor_timeout_s*1000
            locs = x.get('locs')?.toJS()
            if locs?
                #console.log("draw cursors for #{account_id} at #{misc.to_json(locs)} expiring after #{@_other_cursor_timeout_s}s")
                @draw_other_cursors(account_id, locs, x.get('caused'))

    # TODO: this code is almost identical to code in syncdoc.coffee.
    draw_other_cursors: (account_id, locs, caused) =>
        # ensure @_cursors is defined; this is map from key to ...?
        @_cursors ?= {}
        x = @_cursors[account_id]
        if not x?
            x = @_cursors[account_id] = []
        # First draw/update all current cursors
        for [i, loc] in misc.enumerate(locs)
            pos   = {line:loc.y, ch:loc.x}
            data  = x[i]
            name  = misc.trunc(@_users.get_first_name(account_id), 10)
            color = @_users.get_color(account_id)
            if not data?
                if not caused
                    # don't create non user-caused cursors
                    continue
                cursor = @frame.$("<div>").html('<div class="smc-editor-codemirror-cursor"><span class="smc-editor-codemirror-cursor-label"></span><div class="smc-editor-codemirror-cursor-inside">&nbsp;&nbsp;&nbsp;</div></div>')
                cursor.css(position: 'absolute', width:'15em')
                inside = cursor.find(".smc-editor-codemirror-cursor-inside")
                inside.css
                    position : 'absolute'
                    top      : '-1.3em'
                    left     : '1ex'
                    height   : '1.2em'
                    width    : '1px'
                    'border-left' : "1px solid #{color}"

                label = cursor.find(".smc-editor-codemirror-cursor-label")
                label.css
                    'position'         : 'absolute'
                    'top'              : '-2.4em'
                    'font-size'        : '8pt'
                    'font-family'      : 'serif'
                    left               : '1ex'
                    'background-color' : 'rgba(255, 255, 255, 0.8)'
                    'z-index'          : 10000

                label.text(name)
                data = x[i] = {cursor: cursor}
            if name != data.name
                data.cursor.find(".smc-editor-codemirror-cursor-label").text(name)
                data.name = name
            if color != data.color
                data.cursor.find(".smc-editor-codemirror-cursor-inside").css('border-left': "1px solid #{color}")
                data.cursor.find(".smc-editor-codemirror-cursor-label" ).css(color: color)
                data.color = color

            # Place cursor in the editor in the right spot
            @nb?.get_cell(loc.i)?.code_mirror.addWidget(pos, data.cursor[0], false)

            if caused  # if not user caused will have been fading already from when created
                # Update cursor fade-out
                # LABEL: first fade the label out
                data.cursor.find(".smc-editor-codemirror-cursor-label").stop().animate(opacity:1).show().fadeOut(duration:8000)
                # CURSOR: then fade the cursor out (a non-active cursor is a waste of space)
                data.cursor.find(".smc-editor-codemirror-cursor-inside").stop().animate(opacity:1).show().fadeOut(duration:15000)

        if x.length > locs.length
            # Next remove any cursors that are no longer there (e.g., user went from 5 cursors to 1)
            for i in [locs.length...x.length]
                #console.log('removing cursor ', i)
                x[i].cursor.remove()
            @_cursors[account_id] = x.slice(0, locs.length)

    remove: () =>
        if @_sync_check_interval?
            clearInterval(@_sync_check_interval)
        if @_cursor_interval?
            clearInterval(@_cursor_interval)
        if @_autosync_interval?
            clearInterval(@_autosync_interval)
        if @_reconnect_interval?
            clearInterval(@_reconnect_interval)
        @element.remove()
        @doc?.disconnect_from_session()
        @_dead = true

    # Initialize the embedded iframe and wait until the notebook object in it is initialized.
    # If this returns (calls cb) without an error, then the @nb attribute must be defined.
    initialize: (cb) =>
        @dbg("initialize")
        @status("Rendering Jupyter notebook")
        get_with_retry
            url : @server_url
            cb  : (err) =>
                if err
                    @dbg("_init_iframe", "error", err)
                    @status()
                    #console.log("exit _init_iframe 2")
                    cb(err); return

                @iframe_uuid = misc.uuid()
                @dbg("initialize", "loading notebook...")

                @status("Loading Jupyter notebook...")
                @iframe = $("<iframe name=#{@iframe_uuid} id=#{@iframe_uuid}>")
                    .attr('src', "#{@server_url}#{@filename}")
                    .attr('frameborder', '0')
                    .attr('scrolling', 'no')
                @notebook.html('').append(@iframe)
                @show()

                # Monkey patch the IPython html so clicking on the IPython logo pops up a new tab with the dashboard,
                # instead of messing up our embedded view.
                attempts = 0
                delay = 300
                iframe_time = start_time = misc.walltime()
                # What f does below is purely inside the browser DOM -- not the network, so doing it
                # frequently is not a serious problem for the server.
                f = () =>
                    #console.log("iframe_time = ", misc.walltime(iframe_time))
                    if misc.walltime(iframe_time) >= 15
                        # If load fails after about this long, then we hit this error
                        # due to require.js configuration of Ipython, which I don't want to change:
                        #    "Error: Load timeout for modules: services/contents,custom/custom"
                        @iframe = $("<iframe name=#{@iframe_uuid} id=#{@iframe_uuid}>").attr('src', "#{@server_url}#{@filename}")
                        @notebook.html('').append(@iframe)
                        iframe_time = misc.walltime()
                        setTimeout(f,500)
                        return
                    console.log("(attempt #{attempts}, time #{misc.walltime(start_time)}): @frame.ipython=#{@frame?.IPython?}, notebook = #{@frame?.IPython?.notebook?}, kernel= #{@frame?.IPython?.notebook?.kernel?}")
                    if @_dead?
                        cb("dead"); return
                    attempts += 1
                    if delay <= 1000  # exponential backoff up to a bound
                        delay *= 1.4
                    if attempts >= 70
                        # give up after this much time.
                        msg = "Failed to load Jupyter notebook"
                        @status(msg)
                        #console.log("exit _init_iframe 3")
                        cb(msg)
                        return
                    @frame = window.frames[@iframe_uuid]
                    # IT is ***abso-fucking-critical*** to wait until the kernel is connected
                    # before doing anything else!!!!
                    if not @frame?.IPython?.notebook?.kernel?.is_connected()
                        setTimeout(f, delay)
                    else
                        if @opts.read_only
                            $(@frame.document).find("#menubar").remove()
                            $(@frame.document).find("#maintoolbar").remove()

                        a = @frame.$("#ipython_notebook").find("a")
                        if a.length == 0
                            setTimeout(f, delay)
                        else
                            @ipython = @frame.IPython
                            if not @ipython.notebook?
                                msg = "BUG -- Something went wrong -- notebook object not defined in Jupyter frame"
                                @status(msg)
                                #console.log("exit _init_iframe 4")
                                cb(msg)
                                return
                            @nb = @ipython.notebook

                            if @readonly
                                @nb.kernel.stop_channels()

                            a.click () =>
                                @info()
                                return false

                            # Proper file rename with sync not supported yet (but will be -- TODO;
                            # needs to work with sync system)
                            @frame.$("#notebook_name").unbind('click').css("line-height",'0em')

                            # Get rid of file menu, which weirdly and wrongly for sync replicates everything.
                            for cmd in ['new', 'open', 'copy', 'rename']
                                @frame.$("#" + cmd + "_notebook").remove()

                            @frame.$("#save_checkpoint").remove()
                            @frame.$("#restore_checkpoint").remove()
                            @frame.$("#save-notbook").remove()  # in case they fix the typo
                            @frame.$("#save-notebook").remove()  # in case they fix the typo

                            @frame.$(".checkpoint_status").remove()
                            @frame.$(".autosave_status").remove()

                            @frame.$("#menus").find("li:first").find(".divider").remove()

                            # This makes the ipython notebook take up the full horizontal width, which is more
                            # consistent with the rest of SMC.   Also looks better on mobile.
                            @frame.$('<style type=text/css></style>').html(".container{width:98%; margin-left: 0;}").appendTo(@frame.$("body"))

                            if not require('./feature').IS_MOBILE
                                @frame.$("#site").css("padding-left", "20px")

                            # We have our own auto-save system
                            @nb.set_autosave_interval(0)

                            #if @readonly
                            #    @frame.$("#save_widget").append($("<b style='background: red;color: white;padding-left: 1ex; padding-right: 1ex;'>This is a read only document.</b>"))

                            # Convert notebook to a string once, since this
                            # also extracts all the image blobs from the DOM,
                            # so that we don't have to pull all of them from
                            # the backend.
                            @nb_to_string(false)

                            @status()
                            @dbg("initialize", "DONE")
                            cb()

                setTimeout(f, delay)

    autosync: () =>
        if @readonly or @_reloading
            return
        if @nb?.dirty and @nb.dirty != 'clean'
            @dbg("autosync")
            # nb.dirty is used internally by IPython so we shouldn't change it's truthiness.
            # However, we still need a way in Sage to know that the notebook isn't dirty anymore.
            @nb.dirty = 'clean'
            #console.log("causing sync")
            @save_button.removeClass('disabled')
            @sync()

    sync: (cb) =>
        if @readonly or not @doc?
            cb?()
            return
        @editor.activity_indicator(@filename)
        @save_button.icon_spin(start:true, delay:3000)
        @dbg("sync", "start")
        @doc.sync () =>
            @dbg("sync", "done")
            @save_button.icon_spin(false)
            cb?()

    has_unsaved_changes: () =>
        return not @save_button.hasClass('disabled')

    save: (cb) =>
        if not @nb? or @readonly or not @doc?
            cb?(); return
        @save_button.icon_spin(start:true, delay:4000)
        @nb.save_notebook?(false)
        @doc.save () =>
            @save_button.icon_spin(false)
            @save_button.addClass('disabled')
            cb?()

    # Set the the visible notebook in the DOM from the synchronized string
    set_nb_from_doc: () =>
        if not @_initialized
            return
        current = @nb_to_string()
        if not current? or not @doc?
            return
        if @doc.live() != current
            @set_nb(@doc.live())

    info: () =>
        t = "<h3><i class='fa fa-question-circle'></i> About <a href='https://jupyter.org/' target='_blank'>Jupyter Notebook</a></h3>"
        t += "<h4>Enhanced with SageMathCloud Sync</h4>"
        t += "You are editing this document using the Jupyter Notebook enhanced with realtime synchronization and history logging."
        t += "<h4>Use Sage by pasting this into a cell</h4>"
        t += "<pre>%load_ext sage</pre>"
        #t += "<h4>Connect to this Jupyter kernel in a terminal</h4>"
        #t += "<pre>ipython console --existing #{@kernel_id}</pre>"
        t += "<h4>Pure Jupyter notebooks</h4>"
        t += "You can <a target='_blank' href='#{@server_url}#{@filename}'>open this notebook in a vanilla Jupyter Notebook server without sync</a> (this link works only for project collaborators).  "
        #t += "<br><br>To start your own unmodified Jupyter Notebook server that is securely accessible to collaborators, type in a terminal <br><br><pre>ipython-notebook run</pre>"

        # this is still a problem, but removed to avoid overwhelming user.
        #t += "<h4>Known Issues</h4>"
        #t += "If two people edit the same <i>cell</i> simultaneously, the cursor will jump to the start of the cell."
        bootbox.alert(t)
        return false

    reload: () =>
        if @_reloading
            return
        @_reloading = true
        @_cursors = {}
        @reload_button.find("i").addClass('fa-spin')
        @initialize (err) =>
            @_init_doc () =>
                @_reloading = false
                @status('')
                @reload_button.find("i").removeClass('fa-spin')

    init_buttons: () =>
        @element.find("a").tooltip(delay:{show: 500, hide: 100})
        @save_button = @element.find("a[href=#save]").click () =>
            @save()
            return false

        @reload_button = @element.find("a[href=#reload]").click () =>
            @reload()
            return false

        @publish_button = @element.find("a[href=#publish]").click () =>
            @publish_ui()
            return false

        #@element.find("a[href=#json]").click () =>
        #    console.log(@to_obj())

        @element.find("a[href=#info]").click () =>
            @info()
            return false

        @element.find("a[href=#close]").click () =>
            @editor.project_page.display_tab("project-file-listing")
            return false

        @element.find("a[href=#execute]").click () =>
            @nb?.execute_selected_cell()
            return false
        @element.find("a[href=#interrupt]").click () =>
            @nb?.kernel.interrupt()
            return false
        @element.find("a[href=#tab]").click () =>
            @nb?.get_cell(@nb?.get_selected_index()).completer.startCompletion()
            return false

        @element.find("a[href=#history]").show().click(@show_history_viewer)

    publish_ui: () =>
        url = document.URL
        url = url.slice(0,url.length-5) + 'html'
        dialog = templates.find(".smc-jupyter-publish-dialog").clone()
        dialog.modal('show')
        dialog.find(".btn-close").off('click').click () ->
            dialog.modal('hide')
            return false
        status = (mesg, percent) =>
            dialog.find(".smc-jupyter-publish-status").text(mesg)
            p = "#{percent}%"
            dialog.find(".progress-bar").css('width',p).text(p)

        @publish status, (err) =>
            dialog.find(".smc-jupyter-publish-dialog-publishing")
            if err
                dialog.find(".smc-jupyter-publish-dialog-fail").show().find('span').text(err)
            else
                dialog.find(".smc-jupyter-publish-dialog-success").show()
                url_box = dialog.find(".smc-jupyter-publish-url")
                url_box.val(url)
                url_box.click () ->
                    $(this).select()

    publish: (status, cb) =>
        #d = (m) => console.log("ipython.publish('#{@filename}'): #{misc.to_json(m)}")
        #d()
        @publish_button.find("fa-refresh").show()
        async.series([
            (cb) =>
                status?("saving",0)
                @save(cb)
            (cb) =>
                status?("running nbconvert",30)
                @nbconvert
                    format : 'html'
                    cb     : (err) =>
                        cb(err)
            (cb) =>
                status?("making '#{@filename}' public", 70)
                redux.getProjectActions(@editor.project_id).set_public_path(@filename, "Jupyter notebook #{@filename}")
                html = @filename.slice(0,@filename.length-5)+'html'
                status?("making '#{html}' public", 90)
                redux.getProjectActions(@editor.project_id).set_public_path(html, "Jupyter html version of #{@filename}")
                cb()
            ], (err) =>
            status?("done", 100)
            @publish_button.find("fa-refresh").hide()
            cb?(err)
        )

    nbconvert: (opts) =>
        opts = defaults opts,
            format : required
            cb     : undefined
        salvus_client.exec
            path        : @path
            project_id  : @editor.project_id
            command     : 'sage'
            args        : ['-ipython', 'nbconvert', @file, "--to=#{opts.format}"]
            bash        : false
            err_on_exit : true
            timeout     : 30
            cb          : (err, output) =>
                #console.log("nbconvert finished with err='#{err}, output='#{misc.to_json(output)}'")
                opts.cb?(err)

    to_obj: () =>
        #console.log("to_obj: start"); t = misc.mswalltime()
        if not @nb?
            # can't get obj
            return undefined
        obj = @nb.toJSON()
        obj.metadata.name  = @nb.notebook_name
        obj.nbformat       = @nb.nbformat
        obj.nbformat_minor = @nb.nbformat_minor
        #console.log("to_obj: done", misc.mswalltime(t))
        return obj

    delete_cell: (index) =>
        @dbg("delete_cell", index)
        @nb?.delete_cell(index)

    insert_cell: (index, cell_data) =>
        @dbg("insert_cell", index)
        if not @nb?
            return
        new_cell = @nb.insert_cell_at_index(cell_data.cell_type, index)
        try
            new_cell.fromJSON(cell_data)
        catch e
            console.log("insert_cell fromJSON error -- #{e} -- cell_data=",cell_data)
            window.cell_data = cell_data

    set_cell: (index, cell_data) =>
        #console.log("set_cell: start"); t = misc.mswalltime()
        @dbg("set_cell", index, cell_data)
        if not @nb?
            return

        cell = @nb.get_cell(index)

        # Add a new one then deleting existing -- correct order avoids flicker/jump
        new_cell = @nb.insert_cell_at_index(cell_data.cell_type, index)
        try
            new_cell.fromJSON(cell_data)
            if @readonly
                new_cell.code_mirror.setOption('readOnly',true)
            @nb.delete_cell(index + 1)
        catch e
            console.log("set_cell fromJSON error -- #{e} -- cell_data=",cell_data)
        # TODO: If this cell was focused and our cursors were in this cell, we put them back:


        #console.log("set_cell: done", misc.mswalltime(t))

    # Notebook Doc Format: line 0 is meta information in JSON.
    # Rest of file has one line for each cell for rest of file, in JSON format.

    id_to_blob : (id) =>
        @_blobs ?= {}
        blob = @_blobs[id]
        if blob?
            return blob
        else
            # Async fetch it from the database.
            salvus_client.query
                query :
                    blobs :
                        id   : id
                        blob : null
                cb: (err, resp) =>
                    if err
                        console.warn("unable to get blob with id #{id}")
                    else
                        blob = resp.query?.blobs?.blob
                        if blob?
                            @_blobs[id] = blob
                        else
                            console.warn("no blob available with id #{id}")
                        # TODO: at this point maybe just force
                        # update...?  though do some debouncing/throttling in
                        # case a lot of images are being loaded.

    blob_to_id: (blob, save_new_blobs) =>
        @_blobs ?= {}
        id = sha1(blob)
        if not @_blobs[id]?
            @_blobs[id] = blob
            if save_new_blobs
                console.log("saving a new blob with id '#{id}' and value blob='#{misc.trunc(blob,100)}'")
                query =
                    blobs :
                        id         : id
                        blob       : blob
                        project_id : @editor.project_id
                console.log(query)
                window.query = query
                salvus_client.query
                    query : query
                    cb : (err, resp) =>
                        console.log("response from saving: #{err}", resp)
                        # TODO -- cb that on fail will retry the query...
                        # TODO -- maybe only make permanent on save (?)
        return id

    remove_images: (cell, save_new_blobs) =>
        console.log("remove_images: save_new_blobs=#{save_new_blobs}")
        if cell.outputs?
            for out in cell.outputs
                if out.data?
                    for k, v of out.data
                        if k.slice(0,6) == 'image/' and v
                            key = 'smc/' + k
                            if not out.data[key]?
                                out.data[key] = @blob_to_id(v, save_new_blobs)
                                delete out.data[k]

    restore_images: (cell) =>
        if cell.outputs?
            for out in cell.outputs
                if out.data?
                    for k, v of out.data
                        if k.slice(0,4) == 'smc/'
                            blob = @id_to_blob(v)
                            if not blob?
                                return # unable to do it yet
                            out.data[k.slice(4)] = blob
                            # TODO: if blob not defined, we are fetching it
                            # from the database and need to wait or re-render
                            # this cell again.
                            delete out.data[k]
        return true

    cell_to_line: (cell, save_new_blobs) =>
        cell = misc.deep_copy(cell)
        @remove_images(cell, save_new_blobs)
        return JSON.stringify(cell)

    line_to_cell: (line) =>
        try
            cell = misc.from_json(line)
        catch e
            console.warn("line_to_cell('#{line}') -- source ERROR=", e)
            return
        if @restore_images(cell)
            return cell
        else
            return  # undefined means not ready

    # Convert the visible displayed notebook into a textual sync-friendly string
    nb_to_string: (save_new_blobs) =>
        tm = misc.mswalltime()
        #@dbg("nb_to_string", "computing")
        obj = @to_obj()
        if not obj?
            return
        doc = misc.to_json({notebook_name:obj.metadata.name})
        for cell in obj.cells
            doc += '\n' + @cell_to_line(cell, save_new_blobs)
        @nb.dirty = 'clean' # see comment in autosync
        #@dbg("nb_to_string", "time", misc.mswalltime(tm))
        return doc

    # Transform the visible displayed notebook view into exactly what is described by the string doc.
    set_nb: (doc) =>
        @dbg("set_nb")
        tm = misc.mswalltime()
        if not @_initialized
            # The live notebook is not currently initialized -- there's nothing to be done for now.
            # This can happen if reconnect (to hub) happens at the same time that user is reloading
            # the ipython notebook frame itself.   The doc will get set properly at the end of the
            # reload anyways, so no need to set it here.
            return

        # what we want visible document to look like
        goal = doc.split('\n')

        # what the actual visible document looks like
        live = @nb_to_string()?.split('\n')

        if not live? # no visible doc?
            # reloading...
            return

        # first line is metadata...
        @nb.metadata.name  = goal[0].notebook_name

        v0    = live.slice(1)
        v1    = goal.slice(1)
        string_mapping = new misc.StringCharMapping()
        v0_string  = string_mapping.to_string(v0)
        v1_string  = string_mapping.to_string(v1)
        diff = dmp.diff_main(v0_string, v1_string)

        index = 0
        i = 0

        @dbg("set_nb", "diff", diff)
        i = 0
        while i < diff.length
            chunk = diff[i]
            op    = chunk[0]  # -1 = delete, 0 = leave unchanged, 1 = insert
            val   = chunk[1]
            if op == 0
                # skip over  cells
                index += val.length
            else if op == -1
                # Deleting cell
                # A common special case arises when one is editing a single cell, which gets represented
                # here as deleting then inserting.  Replacing is far more efficient than delete and add,
                # due to the overhead of creating codemirror instances (presumably).  (Also, there is a
                # chance to maintain the cursor later.)
                if i < diff.length - 1 and diff[i+1][0] == 1 and diff[i+1][1].length == val.length
                    #console.log("replace")
                    for x in diff[i+1][1]
                        obj = @line_to_cell(string_mapping._to_string[x])
                        if obj?
                            @set_cell(index, obj)
                        index += 1
                    i += 1 # skip over next chunk
                else
                    #console.log("delete")
                    for j in [0...val.length]
                        @delete_cell(index)
            else if op == 1
                # insert new cells
                #console.log("insert")
                for x in val
                    obj = @line_to_cell(string_mapping._to_string[x])
                    if obj?
                        @insert_cell(index, obj)
                    index += 1
            else
                console.log("BUG -- invalid diff!", diff)
            i += 1

        @dbg("set_nb", "time=", misc.mswalltime(tm))

    focus: () =>
        # TODO
        # console.log("ipython notebook focus: todo")

    show: (geometry={}) =>
        @_last_top ?= @editor.editor_top_position()
        {top, left, width, height} = defaults geometry,
            left   : undefined  # not implemented
            top    : @_last_top
            width  : $(window).width()
            height : undefined  # not implemented
        @_last_top = top
        @element.css(top:top)
        if top == 0
            @element.css('position':'fixed')
        # console.log("top=#{top}; setting maxheight for iframe =", @iframe)
        @iframe?.attr('width', width).maxheight()
        setTimeout((()=>@iframe?.maxheight()), 1)   # set it one time more the next render loop.


###
Attempt a more generic well defined approach to sync

- Make an object with this API:

    - set
    - set_cursors
    - get
    - event:
       - 'change'
       - 'ready'
       - 'cursor'
       - 'error'
       - 'info'   - user requests info (clicking on jupyter logo)

States:

  - 'loading'
  - 'ready'
  - 'error'
  - 'closed'

The states of the editor :

  - 'init'   : started initializing
  - 'loading': is loading initial page
  - 'ready'  : page loaded and working
  - 'error'  : tried to load but failed
  - 'closed' : all resources freed

            [failed]  --> [closed]
               /|\           /|\
                |             |
               \|/            |
 [init] --> [loading] --> [ready]


Then something that takes in an object with the above API, and makes it sync.

Idea of how things work.  We view the Jupyter notebook as a block box that
lives in the DOM, which will tell us when it changes, and from which we can
get a JSON-able object representation, and we can set it from such a
representation efficiently without breaking cursors.  Jupyter does *NOT* provide
that functionality, so we implement something like that (you can think of
our approach as "inspired by React.js", but I just came up with it out of
pain and necessity in 2013 long before I heard of React.js).

Here's what happens:

First, assume that the syncstring and the DOM are equal.
There are two event-driven cases in which we handle
that the DOM and syncstring are out of sync.  After each
case, which is handled synchronously, the syncstring and
DOM are equal again.

Case 1: DOM change
 - we set the syncstring equal to the DOM.
 ==> now the syncstring equals the DOM, and syncstring is valid

Case 2: syncstring change
 - if DOM changed since last case 1 or 2, compute patch that transforms DOM from last state we read from
   DOM to current DOM state, and apply that patch to current syncstring.
 - modify syncstring to ensure that each line defines valid JSON.
 - set DOM equal to syncstring
 ==> now the syncstring equals the DOM, and the syncstring is valid

The reason for the asymmetry is that (1) Jupyter doesn't give us a way
to be notified the moment the DOM changes, (2) even if it did, doing
case 1 every keystroke would be inefficient, (3) under the hood
syncstring also does the same sort of merging process.

###

underscore = require('underscore')

class JupyterWrapper extends EventEmitter
    constructor: (@element, url, @read_only, cb) ->
        @state = 'loading'
        @iframe_uuid = misc.uuid()
        @iframe = $("<iframe name=#{@iframe_uuid} id=#{@iframe_uuid}>")
            .attr('src', "#{url}")
            .attr('frameborder', '0')
            .attr('scrolling', 'no')
        @element.html('').append(@iframe)
        # wait until connected -- iT is ***critical*** to wait until
        # the kernel is connected before doing anything else!
        start = new Date()
        max_time_ms = 30*1000 # try for up to 30s
        f = () =>
            @frame ?= window.frames[@iframe_uuid]
            if not @frame
                setTimeout(f, 250)
                return
            if new Date() - start >= max_time_ms
                @state = 'error'
                @error = 'timeout loading'
                @emit('error')
                cb(@error)
            else
                if @frame?.IPython?.notebook?.kernel?.is_connected()
                    # kernel is connected; now patch the Jupyter notebook page (synchronous)
                    @nb = @frame.IPython.notebook
                    console.log("@nb.writable = ", @nb.writable)
                    if not @read_only and not @nb.writable
                        # read_only set to false, but in fact file is read only according to jupyter
                        # server, so we switch to read_only being true.
                        @read_only = true
                    if @read_only
                        # read only -- kill any channels to backend to make evaluation impossible.
                        # Also, ignore any changes to the DOM (shouldn't happen)
                        @nb.kernel.stop_channels()
                        @set_all_cells_read_only()
                    else
                        # not read only -- check for changes to the dump periodically.
                        # It would be dramatically better if Jupyter had an event it would
                        # fire on all changes, but this is what we have.
                        @dirty_interval = setInterval(@check_dirty, 250)
                    @monkey_patch_frame()
                    @disable_autosave()
                    @state = 'ready'
                    @emit('ready')
                    cb()
                else
                    # not yet connected, so try again shortly
                    setTimeout(f, 250)
        f()

    dbg: (f) =>
        return (m) -> salvus_client.dbg("JupyterWrapper.#{f}:")(misc.to_json(m))

    close: () =>
        if @state == 'closed'
            return
        if @dirty_interval?
            clearInterval(@dirty_interval)
            delete @dirty_interval
        @element.html('')
        @removeAllListeners()
        @state = 'closed'

    disable_autosave: () =>
        # We have our own auto-save system
        @nb.set_autosave_interval(0)

    monkey_patch_frame: () =>
        misc_page.cm_define_diffApply_extension(@frame.CodeMirror)
        @monkey_patch_logo()
        if @read_only
            @monkey_patch_read_only()
        @monkey_patch_ui()

    monkey_patch_ui: () =>
        # Proper file rename with sync not supported yet (but will be -- TODO;
        # needs to work with sync system)
        @frame.$("#notebook_name").unbind('click').css("line-height",'0em')

        # Get rid of file menu, which weirdly and wrongly for sync replicates everything.
        for cmd in ['new', 'open', 'copy', 'rename']
            @frame.$("#" + cmd + "_notebook").hide()

        @frame.$("#save_checkpoint").hide()
        @frame.$("#restore_checkpoint").hide()
        @frame.$("#save-notbook").hide()   # in case they fix the typo
        @frame.$("#save-notebook").hide()  # in case they fix the typo

        @frame.$(".checkpoint_status").hide()
        @frame.$(".autosave_status").hide()

        @frame.$("#menus").find("li:first").find(".divider").hide()

        # This makes the ipython notebook take up the full horizontal width, which is more
        # consistent with the rest of SMC.   Also looks better on mobile.
        @frame.$('<style type=text/css></style>').html(".container{width:98%; margin-left: 0;}").appendTo(@frame.$("body"))

        if not require('./feature').IS_MOBILE
            @frame.$("#site").css("padding-left", "20px")

    monkey_patch_logo: () =>
        @frame.$("#ipython_notebook").find("a").click () =>
            @emit('info')
            return false

    monkey_patch_read_only: () =>
        $(@frame.document).find("#menubar").hide()
        $(@frame.document).find("#maintoolbar").hide()

    check_dirty: () =>
        if @nb.dirty and @nb.dirty != 'clean'
            # nb.dirty is used internally by IPython so we shouldn't change it's truthiness.
            # However, we still need a way in Sage to know that the notebook isn't dirty anymore.
            @nb.dirty = 'clean'
            @emit('change')

    set0: (obj) =>
        obj =
            content : obj
            name    : @nb.notebook_name
            path    : @nb.notebook_path
        @nb.fromJSON(obj)
        if @read_only
            @set_all_cells_to_read_only()

    set_all_cells_read_only: () =>
        for i in [0...@nb.ncells()]
            @nb.get_cell(i).code_mirror.setOption('readOnly',true)

    get0: () =>
        return @nb.toJSON()


    # Transform the visible displayed notebook view into what is described by the string doc.
    # Returns string that actually got set, in case the doc string is partly invalid.
    set: (doc) =>
        try
            @_set_via_mutate(doc)
            return doc  # if set_via_mutate works, it **should** work perfectly
        catch err
            console.warn("Setting Jupyter DOM via mutation failed; instead setting fromJSON")
            v = doc.split('\n')
            obj = {cells:[]}
            try
                x = JSON.parse(v[0])
            catch err
                console.warn("Error parsing notebook_name JSON '#{v[0]}' -- #{err}")
                x = {}
            if x.notebook_name?
                @nb.metadata.name = x.notebook_name
            if x.metadata?
                obj.metadata = x.metadata
            else
                # fallback -- try to use the last object that @get() returned.
                obj.metatada = @_last_obj?.metadata ? @nb.toJSON().metadata
            i = 0
            for x in v.slice(1)
                try
                    obj.cells.push(JSON.parse(x))
                catch err
                    console.warn("Error parsing JSON '#{x}' -- #{err}")
                    # Arbitrary strategy: take the ith cell from the DOM and use that. Often
                    # this will be right, and there is no way to know in general.  User has
                    # full history, so they can manually resolve anything.
                    try
                        obj.cells.push(@nb.get_cell(i))
                    catch err
                        # Maybe there is no ith cell...
                        console.warn("Fallback to ith cell didn't work")
                i += 1
            @set0(obj)
            return @get()

    _set_via_mutate: (doc) =>
        dbg = @dbg("set")
        dbg()
        if typeof(doc) != 'string'
            throw "BUG -- set: doc must be of type string"

        # what we want visible document to look like
        goal = doc.split('\n')

        # what the actual visible document looks like
        live = @get().split('\n')

        # first line is metadata...
        @nb.metadata.name = goal[0].notebook_name

        v0    = live.slice(1)
        v1    = goal.slice(1)
        string_mapping = new misc.StringCharMapping()
        v0_string  = string_mapping.to_string(v0)
        v1_string  = string_mapping.to_string(v1)
        diff = dmp.diff_main(v0_string, v1_string)

        index = 0
        i = 0

        @dbg("diff", diff)
        i = 0
        while i < diff.length
            chunk = diff[i]
            op    = chunk[0]  # -1 = delete, 0 = leave unchanged, 1 = insert
            val   = chunk[1]
            if op == 0
                # skip over  cells
                index += val.length
            else if op == -1
                if i < diff.length - 1 and diff[i+1][0] == 1 and diff[i+1][1].length == val.length
                    # Replace Cell:  insert and delete
                    # A common special case arises when one is editing a single cell, which gets represented
                    # here as deleting then inserting.  Replacing is far more efficient than delete and add,
                    # due to the overhead of creating codemirror instances (presumably).  Also, we can
                    # maintain the user cursors and local-to-that-cell undo history.
                    for x in diff[i+1][1]
                        obj = @line_to_cell(string_mapping._to_string[x])
                        if obj?
                            @mutate_cell(index, obj)
                        index += 1
                    i += 1 # skip over next chunk
                else
                    # Deleting cell
                    for j in [0...val.length]
                        @delete_cell(index)
            else if op == 1
                # Create new cells
                for x in val
                    obj = @line_to_cell(string_mapping._to_string[x])
                    if obj?
                        @insert_cell(index, obj)
                    index += 1
            else
                console.log("BUG -- invalid diff!", diff)
            i += 1

    line_to_cell: (line) =>
        cell = JSON.parse(line)

    cell_to_line: (cell) =>
        # TODO: remove images and ensure stored in blob store.
        return JSON.stringify(cell)

    set_cell: (index, obj) =>
        dbg = @dbg("set_cell")
        dbg(index, obj)
        cell = @nb.get_cell(index)
        cm = cell.code_mirror
        cm_setValueNoJump(cm, obj.source) #
        # Add a new one then deleting existing -- correct order avoids flicker/jump
        new_cell = @nb.insert_cell_at_index(obj.cell_type, index)
        new_cell.fromJSON(obj)
        # Swap the codemirror, so we preserve cursors and local history.
        cell.code_mirror = new_cell.code_mirror
        new_cell.code_mirror = cm
        @nb.delete_cell(index + 1)
        # TODO: readonly

    mutate_cell: (index, obj) =>
        dbg = @dbg("mutate_cell")
        dbg(index, obj)
        cell = @nb.get_cell(index)
        obj0 = cell.toJSON()
        if obj0.source != obj.source
            # only source differs
            cm_setValueNoJump(cell.code_mirror, obj.source)
            cell.auto_highlight()
        # TODO: when code running the asterisk doesn't sync out
        if obj0.execution_count != obj.execution_count
            cell.set_input_prompt(obj.execution_count)
        if not underscore.isEqual(obj0.outputs, obj.outputs) or not underscore.isEqual(obj0.metadata, obj.metadata)
            cell.output_area.clear_output(false, true)
            cell.output_area.trusted = !!obj.metadata.trusted
            cell.output_area.fromJSON(obj.outputs, obj.metadata)

    delete_cell: (index) =>
        @dbg("delete_cell")(index)
        @nb.delete_cell(index)

    insert_cell: (index, obj) =>
        @dbg("insert_cell")(index, obj)
        new_cell = @nb.insert_cell_at_index(obj.cell_type, index)
        new_cell.fromJSON(obj)
        if @read_only
            new_cell.code_mirror.setOption('readOnly',true)

    # Convert the visible displayed notebook into a textual sync-friendly string
    get: () =>
        obj = @nb.toJSON()
        @_last_obj = obj
        doc = JSON.stringify({notebook_name: @nb.notebook_name, metadata:obj.metadata})
        for cell in obj.cells
            doc += '\n' + @cell_to_line(cell)
        return doc

    show: (width) =>
        @iframe?.attr('width', width).maxheight()
        setTimeout((()=>@iframe?.maxheight()), 1)   # set it one time more the next render loop.

class JupyterNotebook2
    constructor: (@editor, @filename, opts={}) ->
        opts = @opts = defaults opts,
            read_only : false
            mode      : undefined   # ignored
        window.s = @
        @read_only = opts.read_only
        @element = templates.find(".smc-jupyter-notebook").clone()
        @element.data("jupyter_notebook", @)
        @project_id = @editor.project_id

        # Jupyter is proxied via the following canonical URL:
        @server_url = "#{window.smc_base_url}/#{@editor.project_id}/port/jupyter/notebooks/"

        # special case/hack for developing SMC-in-SMC
        if window.smc_base_url.indexOf('/port/') != -1
            # Hack until we can figure out how to proxy websockets through a proxy
            # (things just get too complicated)...
            console.warn("Jupyter: assuming that SMC is being run from a project installed in the ~/smc directory!!")
            i = window.smc_base_url.lastIndexOf('/')
            @server_url = "#{window.smc_base_url.slice(0,i)}/jupyter/notebooks/smc/src/data/projects/#{@editor.project_id}/"

        s = misc.path_split(@filename)
        @path = s.head
        @file = s.tail

        # filename for our sync-friendly representation of the Jupyter notebook
        @syncdb_filename = (if @path then (@path+'/.') else '.') + @file + IPYTHON_SYNCFILE_EXTENSION

        # where we will put the page itself
        @notebook = @element.find(".smc-jupyter-notebook-notebook")

        # Load the notebook and transition state to either 'ready' or 'failed'
        @state = 'init'
        @load()

    close: () =>
        if @state == 'closed'
            return
        @dom?.close()
        delete @dom
        @syncstring?.close()
        delete @syncstring
        @state = 'closed'

    dbg: (f) =>
        return (m) -> salvus_client.dbg("JupyterNotebook.#{f}:")(misc.to_json(m))

    load: (cb) =>
        if @state != 'init' and @state != 'failed'
            cb("load BUG: @state must be init or failed")
            return

        @state = 'loading'
        connect = (cb) =>
        async.parallel [@init_syncstring, @init_dom], (err) =>
            if err
                @state = 'failed'
            else
                @init_dom_change()
                @init_syncstring_change()
                @init_dom_events()
                @state = 'ready'
            cb?(err)

    init_syncstring: (cb) =>
        dbg = @dbg("init_syncstring")
        if @state != 'loading'
            cb("init_syncfile BUG: @state must be loading")
            return
        dbg("initializing synchronized string '#{@syncdb_filename}'")
        syncdoc.synchronized_string
            project_id : @project_id
            filename   : @syncdb_filename
            cb         : (err, s) =>
                @syncstring = s
                cb(err)

    init_dom: (cb) =>
        if @state != 'loading'
            cb("init_dom BUG: @state must be loading")
            return
        done = (err) =>
            if err
                cb(err)
            else
                if @dom.read_only
                    # DOM gets extra info about @read_only status of file from jupyter notebook server.
                    @read_only = true
                cb()
        @dom = new JupyterWrapper(@notebook, "#{@server_url}#{@filename}", @read_only, done)
        @show()

    init_dom_events: () =>
        @dom.on('info', @info)

    # listen for and handle changes to the live document
    init_dom_change: () =>
        if @read_only
            # read-only mode: ignore any DOM changes
            return
        dbg = @dbg("dom_change")
        @_last_dom = @dom.get()
        handle_dom_change = () =>
            dbg()
            new_ver = @dom.get()
            @_last_dom = new_ver
            @syncstring.live(new_ver)
            @syncstring.save()
        #@dom.on('change', handle_dom_change)
        # test this:
        # We debounce so that no matter what the live doc has to be still for 2s before
        # we handle any changes to it.  Since handling changes can be expensive this avoids
        # slowing the user down.  Making the debounce value large is also useful for
        # testing edge cases of the sync algorithm.
        @dom.on('change', underscore.debounce(handle_dom_change, 500))

    # listen for changes to the syncstring
    init_syncstring_change: () =>
        dbg = @dbg("syncstring_change")
        last_syncstring = @syncstring.live()
        handle_syncstring_change = () =>
            live = @syncstring.live()
            if last_syncstring != live
                # it really did change
                dbg()
                cur_dom = @dom.get()
                if @_last_dom != cur_dom
                    patch = dmp.patch_make(@_last_dom, cur_dom)
                    live = dmp.patch_apply(patch, live)[0]
                    @_last_dom = cur_dom
                    @syncstring.live(live)
                last_syncstring = live
                if cur_dom != live
                    @_last_dom = result = @dom.set(live)
                    if result != live
                        # Something went wrong during set, e.g., JSON parsing issue.
                        # The following sets the syncstring to be definitely valid
                        # and equal to what is in the DOM.
                        last_syncstring = live = result
                        @syncstring.live(result)
                        @syncstring.sync()
                # Now DOM equals syncstring.

        @syncstring.on('sync', handle_syncstring_change)

    ipynb_timestamp: (cb) =>
        dbg = @dbg("ipynb_timestamp")
        dbg("get when .ipynb file last modified")
        get_timestamp
            project_id : @project_id
            path       : @filename
            cb         : cb

    syncstring_timestamp: () =>
        dbg = @dbg("syncstring_timestamp")
        dbg("get when .ipynb file last modified")
        if @state != 'ready'
            throw "BUG -- syncstring_timestamp -- state must be ready (but it is '#{@state}')"
            return
        return @syncstring._syncstring.last_changed() - 0

    show: (geometry={}) =>
        @_last_top ?= @editor.editor_top_position()
        {top, left, width, height} = defaults geometry,
            left   : undefined  # not implemented
            top    : @_last_top
            width  : $(window).width()
            height : undefined  # not implemented
        @_last_top = top
        @element.css(top:top)
        if top == 0
            @element.css('position':'fixed')
        @dom.show(width)

    info: () =>
        t = "<h3><i class='fa fa-question-circle'></i> About <a href='https://jupyter.org/' target='_blank'>Jupyter Notebook</a></h3>"
        t += "<h4>Enhanced with SageMathCloud Sync</h4>"
        t += "You are editing this document using the Jupyter Notebook enhanced with realtime synchronization and history logging."
        t += "<h4>Use Sage by pasting this into a cell</h4>"
        t += "<pre>%load_ext sage</pre>"
        #t += "<h4>Connect to this Jupyter kernel in a terminal</h4>"
        #t += "<pre>ipython console --existing #{@kernel_id}</pre>"
        t += "<h4>Pure Jupyter notebooks</h4>"
        t += "You can <a target='_blank' href='#{@server_url}#{@filename}'>open this notebook in a vanilla Jupyter Notebook server without sync</a> (this link works only for project collaborators).  "
        #t += "<br><br>To start your own unmodified Jupyter Notebook server that is securely accessible to collaborators, type in a terminal <br><br><pre>ipython-notebook run</pre>"

        # this is still a problem, but removed to avoid overwhelming user.
        #t += "<h4>Known Issues</h4>"
        #t += "If two people edit the same <i>cell</i> simultaneously, the cursor will jump to the start of the cell."
        bootbox.alert(t)
        return false

get_timestamp = (opts) ->
    opts = defaults opts,
        project_id : required
        path       : required
        cb         : required
    salvus_client.exec
        project_id : opts.project_id
        command    : "stat"   # %Z below = time of last change, seconds since Epoch; use this not %Y since often users put file in place, but with old time
        args       : ['--printf', '%Z ', opts.path]
        timeout    : 20
        err_on_exit: false
        cb         : (err, output) =>
            if err
                opts.cb(err)
            else if output.stderr.indexOf('such file or directory') != -1
                # file doesn't exist
                opts.cb(undefined, 0)
            else
                opts.cb(undefined, parseInt(output.stdout)*1000)

cm_setValueNoJump = (cm, value) ->
    cm.diffApply(dmp.diff_main(cm.getValue(), value))

