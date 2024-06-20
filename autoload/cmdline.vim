let g:cmdline#_namespace = has('nvim') ? nvim_create_namespace('cmdline') : 0

const s:priority_highlight_prompt = 0
const s:priority_highlight_cursor = 1

function cmdline#_get() abort
  if !'s:cmdline'->exists()
    call cmdline#_init()
  endif
  return s:cmdline
endfunction
function cmdline#_init() abort
  let s:cmdline = #{
        \   buf: -1,
        \   id: -1,
        \   pos: [],
        \   prompt: '',
        \   hl_msg: has('nvim') ? '' : [],
        \   hl_cursor: has('nvim') ? '' : [],
        \   t_ve: has('nvim') ? '' : &t_ve,
        \ }
endfunction
function cmdline#_init_options() abort
  let s:options = #{
        \   blend: '+pumblend'->exists() ? &pumblend : 0,
        \   border: 'single',
        \   col: (&columns - 80) / 2 - 10,
        \   highlight_cursor: 'Cursor',
        \   highlight_prompt: 'Question',
        \   highlight_window: 'Normal',
        \   row: &lines / 2,
        \   width: 80,
        \   zindex: 1000,
        \ }
endfunction
function cmdline#_options() abort
  if !'s:options'->exists()
    call cmdline#_init_options()
  endif

  return s:options->copy()
endfunction

function cmdline#set_option(key_or_dict, value = '') abort
  if !'s:options'->exists()
    call cmdline#_init_options()
  endif

  const dict = cmdline#util#_normalize_key_or_dict(a:key_or_dict, a:value)
  call s:check_options(dict)

  call extend(s:options, dict)
endfunction
function s:check_options(options) abort
  const default_keys = s:options->keys()

  for key in a:options->keys()
    if default_keys->index(key) < 0
      call cmdline#util#_print_error('Invalid option: ' .. key)
    endif
  endfor
endfunction

function cmdline#input(
      \ prompt='', text='', completion='custom,cmdline#_dummy') abort

  let cmdline = cmdline#_get()
  let cmdline.prompt = a:prompt

  if cmdline#enable()
    return ''
  endif

  const input = a:prompt->input(a:text, a:completion)

  call cmdline#_close()

  return input
endfunction

function cmdline#enable() abort
  if !has('patch-9.0.1276') && !has('nvim-0.8')
    call cmdline#_print_error(
          \ 'cmdline.vim requires Vim 9.0.1276+ or neovim 0.8.0+.')
    return -1
  endif

  let cmdline = cmdline#_get()
  let options = cmdline#_options()

  const text = printf('%s %s', cmdline.prompt, getcmdline())

  const hl_normal = has('nvim') ?
        \ nvim_get_hl(0, #{ name: 'Normal'}) : 'Normal'->hlget()
  const hl_msg = has('nvim') ?
        \ nvim_get_hl(0, #{ name: 'MsgArea'}) : 'MsgArea'->hlget()
  const hl_cursor = has('nvim') ?
        \ nvim_get_hl(0, #{ name: 'Cursor'}) : 'Cursor'->hlget()

  if has('nvim')
    if cmdline.buf < 0
      let cmdline.buf = nvim_create_buf(v:false, v:true)
    endif

    call nvim_buf_set_lines(cmdline.buf, 0, -1, v:true, [text])

    let winopts = #{
          \   border: options.border,
          \   relative: 'editor',
          \   width: [text->strwidth(), options.width]->max(),
          \   height: 1,
          \   row: options.row,
          \   col: options.col,
          \   anchor: 'NW',
          \   style: 'minimal',
          \   zindex: options.zindex,
          \ }

    if cmdline.id > 0
      " Reuse window
      call nvim_win_set_config(cmdline.id, winopts)
    else
      call cmdline#_close()

      " NOTE: It cannot set in nvim_win_set_config()
      let winopts.noautocmd = v:true

      " Create new window
      const id = nvim_open_win(cmdline.buf, v:false, winopts)

      call s:set_float_window_options(id, options, 'window')

      let cmdline.id = id
    endif

    let hidden_base = hl_normal->copy()
    if hidden_base->has_key('bg')
      let hidden_base.fg = hidden_base.bg
    else
      " For transparency
      let hidden_base.fg = 0
      let hidden_base.bg = 0
    endif

    call nvim_set_hl(0, 'MsgArea', hidden_base)
    call nvim_set_hl(0, 'Cursor', hidden_base)
  else
    let winopts = #{
          \   pos: 'topleft',
          \   line: options.row + 1,
          \   col: options.col + 1,
          \   highlight: options.highlight_window,
          \   maxheight: 1,
          \   minwidth: options.width,
          \   wrap: v:true,
          \   zindex: options.zindex,
          \ }

    if options.border->type() ==# v:t_string
      if options.border ==# 'double'
        let winopts.border = [2, 2, 2, 2]
      elseif options.border !=# 'none'
        let winopts.border = [1, 1, 1, 1]
      endif
    else
      let winopts.borderchars = options.border
    endif

    if cmdline.id > 0
      call popup_move(cmdline.id, winopts)
      call popup_settext(cmdline.id, [])
    else
      let cmdline.id = [text]->popup_create(winopts)
      let cmdline.buf = cmdline.id->winbufnr()
    endif

    " NOTE: Disable cursor
    let cmdline.t_ve = &t_ve
    set t_ve=

    let hidden_base = hl_normal[0]->copy()
    if hidden_base->has_key('guifg')
      let hidden_base.guifg = hidden_base.guibg
    endif
    if hidden_base->has_key('ctermfg')
      let hidden_base.ctermfg = hidden_base.guibg
    endif

    let hidden_msgarea = hidden_base->copy()
    let hidden_msgarea.name = 'MsgArea'

    let hidden_cursor = hidden_base->copy()
    let hidden_cursor.name = 'Cursor'

    call hlset([
          \   hidden_msgarea,
          \   hidden_cursor,
          \ ])
  endif

  let cmdline.pos = [options.row, options.col]
  let cmdline.hl_msg = hl_msg
  let cmdline.hl_cursor = hl_cursor

  augroup cmdline
    autocmd CmdlineEnter,CmdlineChanged * ++nested call s:redraw_cmdline()
    autocmd CmdlineLeave,VimLeavePre * ++nested call cmdline#_close()
  augroup END

  if '##CursorMovedC'->exists()
    autocmd cmdline CursorMovedC * ++nested call s:redraw_cmdline()
  endif

  " NOTE: redraw is needed
  redraw
endfunction

function cmdline#_dummy(arglead, cmdline, cursor) abort
  return ''
endfunction

function cmdline#_close() abort
  let cmdline = cmdline#_get()
  if cmdline.id < 0
    return
  endif

  if has('nvim')
    call nvim_win_close(cmdline.id, v:true)

    call nvim_set_hl(0, 'MsgArea', cmdline.hl_msg)
    call nvim_set_hl(0, 'Cursor', cmdline.hl_cursor)
  else
    " NOTE: prop_remove() is not needed.
    " popup_close() removes the buffer.
    call popup_close(cmdline.id)

    call hlset(cmdline.hl_msg + cmdline.hl_cursor)

    let &t_ve = cmdline.t_ve
  endif

  let cmdline.id = -1
  let cmdline.prompt = ''
  let cmdline.pos = []

  augroup cmdline
    autocmd!
  augroup END
endfunction

function s:redraw_cmdline() abort
  let cmdline = cmdline#_get()
  if cmdline.id < 0
    return
  endif

  const text = printf('%s %s ', cmdline.prompt, getcmdline())

  call setbufline(cmdline.buf, 1, text)

  let options = cmdline#_options()

  if has('nvim')
    " NOTE: auto resize width
    call nvim_win_set_config(cmdline.id, #{
          \   width: [text->strwidth(), options.width]->max(),
          \ })

    " Clear highlights
    call nvim_buf_clear_namespace(cmdline.buf, g:cmdline#_namespace, 1, -1)
  endif

  " Highlight the cursor
  call s:overwrite_highlight(
        \ options.highlight_cursor,
        \ 'cmdline_highlight_cursor',
        \ -1,
        \ s:priority_highlight_cursor,
        \ 1, cmdline.prompt->strlen() + getcmdpos() + 1, 1)

  " Highlight the prompt
  if cmdline.prompt !=# ''
    call s:overwrite_highlight(
          \ options.highlight_prompt,
          \ 'cmdline_highlight_prompt',
          \ -1,
          \ s:priority_highlight_prompt,
          \ 1, 1, cmdline.prompt->strlen())
  endif

  " NOTE: ":redraw" is needed to update screen in command line.
  redraw
endfunction

function s:set_float_window_options(id, options, highlight) abort
  let highlight = 'NormalFloat:' .. a:options['highlight_' .. a:highlight]
  let highlight ..= ',FloatBorder:FloatBorder,CursorLine:Visual'
  if &hlsearch
    " Disable 'hlsearch' highlight
    let highlight ..= ',Search:None,CurSearch:None'
  endif

  call setwinvar(a:id, '&winhighlight', highlight)
  call setwinvar(a:id, '&winblend', a:options.blend)
  call setwinvar(a:id, '&wrap', v:true)
  call setwinvar(a:id, '&scrolloff', 0)
endfunction

function cmdline#_print_error(string, name = 'cmdline') abort
  echohl Error
  for line in
        \ (a:string->type() ==# v:t_string ? a:string : a:string->string())
        \ ->split("\n")->filter({ _, val -> val != ''})
    echomsg printf('[%s] %s', a:name, line)
  endfor
  echohl None
endfunction

function s:highlight(highlight, prop_type, priority, row, col, length) abort
  let cmdline = cmdline#_get()

  if has('nvim')
    return nvim_buf_set_extmark(
          \ cmdline.buf, g:cmdline#_namespace, a:row - 1, a:col - 1, #{
          \   end_col: a:col - 1 + a:length,
          \   hl_group: a:highlight,
          \   priority: a:priority,
          \ })
  else
    " Add prop_type
    if a:prop_type->prop_type_get()->empty()
      call prop_type_add(a:prop_type, #{
            \   highlight: a:highlight,
            \   priority: a:priority,
            \ })
    endif
    call prop_add(a:row, a:col, #{
          \   length: a:length,
          \   type: a:prop_type,
          \   bufnr: cmdline.buf,
          \ })
    return -1
  endif
endfunction

function s:clear_highlight(prop_type, id) abort
  let cmdline = cmdline#_get()

  if has('nvim')
    call nvim_buf_del_extmark(cmdline.buf, g:cmdline#_namespace, a:id)
  elseif !a:prop_type->prop_type_get()->empty()
    call prop_remove(#{
          \   type: a:prop_type,
          \   bufnr: cmdline.buf,
          \ })
  endif
endfunction

function s:overwrite_highlight(
      \ highlight, prop_type, id, priority, row, col, length) abort
  call s:clear_highlight(a:prop_type, a:id)
  call s:highlight(
        \ a:highlight, a:prop_type, a:priority, a:row, a:col, a:length)
endfunction
