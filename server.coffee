express = require 'express'
events = require 'events'
request = require 'request'
level = require 'level'
marked = require 'marked'

hljs = require('highlight.js')
marked.setOptions highlight: (code, lang) ->
  # If the language is wacky, this throws.
  try
    if lang
      hljs.highlight(lang, code).value
    else
      hljs.highlightAuto(code).value
  catch
    code

OWNER = 'josephg@gmail.com'

db = level 'text', valueEncoding: 'json'

reindex = (callback) ->
  ws = db.createWriteStream type:'del'
  rs = db.createReadStream start:'idx/', end:'idx/~', valueEncoding:'utf8'
  rs.pipe(ws).on 'close', ->
    rs = db.createValueStream start:'posts/', end:'posts/~'
    batch = db.batch()

    rs.on 'data', (d) -> indexPost d, batch
    rs.on 'close', ->
      console.log 'reindexed'
      batch.write callback

indexPost = (post, batch) ->
  batch.put "idx/by_date/#{post.created_at}", post.slug, valueEncoding:'utf8'

  if post.published
    batch.put "idx/published/#{post.created_at}", post.slug, valueEncoding:'utf8'
  else
    batch.del "idx/published/#{post.created_at}"

deIndex = (post, batch) ->
  batch.del "idx/by_date/#{post.created_at}"
  if post.published
    batch.del "idx/published/#{post.created_at}"


#reindex()

getPosts = (path, opts, callback) ->
  [opts, callback] = [{}, opts] if typeof opts is 'function'

  if opts.reverse
    opts.start = path + '~'
    opts.end = path
  else
    opts.start = path
    opts.end = path + '~'

  opts.keys = no
  opts.valueEncoding = 'utf8'

  # Published posts are indexed by creation time.
  rs = db.createValueStream opts

  docs = []
  tasks = 0
  idx = 0
  
  doneTask = ->
    tasks++
    if tasks == docs.length + 1
      callback null, docs

  rs.on 'data', (slug) ->
    i = idx++
    db.get "posts/#{slug}", (err, data) ->
      #console.log 'getposts', err, data
      docs[i] = data
      doneTask()

  rs.on 'close', doneTask

putPost = (post, callback) ->
  batch = db.batch().put "posts/#{post.slug}", post
  indexPost post, batch
  batch.write callback

delPost = (slug, callback) ->
  db.get "posts/#{slug}", (err, post) ->
    batch = db.batch().del "posts/#{slug}"
    deIndex post, batch
    batch.write (err) ->
      #console.log 'deindex err', err
      callback err

app = express()

app.engine 'html', require('consolidate').toffee
app.set 'view engine', 'html'
app.set 'views', __dirname + '/views'

app.use express.logger 'dev'
app.use express.static __dirname + '/static'
app.use express.static __dirname + '/node_modules/marked/lib'
app.use express.bodyParser()
app.use app.router
app.use express.cookieParser 'asdkfkajhdfawefhakej faljkwef lkawef akwjhf'
app.use express.session()
#app.use express.csrf()

# Middleware to make sure a user is logged in before allowing them to access the page.
# You could improve this by setting a redirect URL to the login page, and then redirecting back
# after they've authenticated.
restrict = (req, res, next) ->
  return next()
  return next() if req.session.user
  res.redirect '/login'

app.post '/auth', (req, res, next) ->
  return next(new Error 'No assertion in body') unless req.body.assertion

  # Persona has given us an assertion, which needs to be verified. The easiest way to verify it
  # is to get mozilla's public verification service to do it.
  #
  # The audience field is hardcoded, and does not use the HTTP headers or anything. See:
  # https://developer.mozilla.org/en-US/docs/Persona/Security_Considerations
  request.post 'https://verifier.login.persona.org/verify',
    form:
      audience:req.headers.host
      assertion:req.body.assertion
    (err, _, body) ->
      return next(err) if err

      try
        data = JSON.parse body
      catch e
        return next(e)

      return next(new Error data.reason) unless data.status is 'okay'

      return next(new Error "Unauthorized user") unless data.email is OWNER

      # Login worked.
      req.session.user = data.email
      res.redirect '/admin'

# We need to do 2 things during logout:
# - Delete the user's logged in status from their session object (ie, record they've been
#   logged out on the server)
# - Tell persona they've been logged out in the browser.
app.get '/logout', restrict, (req, res, next) ->
  res.render 'logout', user: req.session.user
  delete req.session.user

# The login page needs CSRF (cross-site request forging) protection. The token is generated by
# the express.csrf() middleware, its injected into the hidden login form and then automatically
# checked when the login form is submitted.
app.get '/login', (req, res) ->
  res.render 'login', csrf:req.session._csrf, user:req.session.user

slugFromTitle = (title) ->
  title.toLowerCase().replace(/[^a-z]+/g, '-').substr(0,25).replace(/-$/,'')

app.get '/admin', restrict, (req, res) ->
  getPosts 'idx/by_date/', (err, posts) ->
    res.setHeader 'cache-control', 'no-store'
    res.render 'admin',
      user: req.session.user
      slugFromTitle: slugFromTitle.toString()
      ideas: (p for p in posts when !p.published)
      published: (p for p in posts when p.published)

app.post '/api/add', restrict, (req, res) ->
  data = req.body
  post =
    type: 'post'
    title: data.title
    body: data.body ? ''
    published: data.published ? false
    created_at: (new Date).toISOString()
    slug: data.slug ? slugFromTitle(data.title)
  putPost post, (err) ->
    return res.json 500, ok: no, err: err if err
    res.json ok: yes

app.post '/api/delete', restrict, (req, res) ->
  delPost req.body.slug, (err) ->
    if err
      return res.json 500, ok: no, err: err
    res.json ok: yes

app.post '/api/update', restrict, (req, res) ->
  data = req.body
  db.get "posts/#{data.slug}", (err, r) ->
    throw err if err
    for k,v of data.update when k in ['title', 'body', 'published']
      r[k] = v
    putPost r, (err) ->
      throw err if err
      res.json ok: yes

renderPost = (req, res, opts = {}) ->
  db.get "posts/#{req.params.slug}", (err, post) ->
    # TODO 404
    return res.end() if !post

    opts.post = post
    opts.model = !!opts.model
    opts.md = marked
    res.render 'text', opts

app.get '/', (req, res) ->
  last = process.hrtime()

  getPosts 'idx/published/', limit:10, reverse:yes, (err, posts) ->
    #db.view 'posts/published', { include_docs: true, descending: true, limit: 10 }, (err, posts) ->
    res.render 'index', md: marked, posts: posts

app.get '/:slug', (req, res) ->
  renderPost req, res

app.get '/:slug/edit', restrict, (req, res) ->
  renderPost req, res, model: true

port = process.argv[2] ? 8000
app.listen port
console.log "Listening on http://localhost:#{port}"
