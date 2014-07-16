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

OWNER = 'me@josephg.com'

db = level 'db', valueEncoding: 'json'

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

#app.use express.logger 'dev'
app.use express.static __dirname + '/static'
app.use express.static __dirname + '/node_modules/marked/lib'
app.use express.static process.env['HOME'] + '/public'
app.use express.bodyParser()
app.use express.cookieParser()

#app.use express.session()
#app.use express.csrf()
session = express.cookieSession secret:'adsffdasdsSDGA$@%P!13', proxy:true
app.use app.router


# Middleware to make sure a user is logged in before allowing them to access the page.
# You could improve this by setting a redirect URL to the login page, and then redirecting back
# after they've authenticated.
restrict = (req, res, next) ->
  return next() if req.session.user
  res.redirect '/login'

app.post '/auth', session, (req, res, next) ->
  return next(new Error 'No assertion in body') unless req.body.assertion

  # Persona has given us an assertion, which needs to be verified. The easiest way to verify it
  # is to get mozilla's public verification service to do it.
  #
  # The audience field is hardcoded, and does not use the HTTP headers or anything. See:
  # https://developer.mozilla.org/en-US/docs/Persona/Security_Considerations
  request.post 'https://verifier.login.persona.org/verify',
    form:
      audience:'josephg.com'
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
app.get '/logout', session, (req, res, next) ->
  res.render 'logout', user: req.session?.user
  delete req.session.user if req.session
  req.session = null

# The login page needs CSRF (cross-site request forging) protection. The token is generated by
# the express.csrf() middleware, its injected into the hidden login form and then automatically
# checked when the login form is submitted.
app.get '/login', session, (req, res) ->
  res.render 'login', csrf:req.session._csrf, user:req.session.user

slugFromTitle = (title) ->
  title.toLowerCase().replace(/[^a-z]+/g, '-').substr(0,25).replace(/-$/,'')

app.get '/admin', session, restrict, (req, res) ->
  getPosts 'idx/by_date/', (err, posts) ->
    res.setHeader 'cache-control', 'no-store'
    res.render 'admin',
      user: req.session.user
      slugFromTitle: slugFromTitle.toString()
      ideas: (p for p in posts when !p.published)
      published: (p for p in posts when p.published)

app.post '/api/add', session, restrict, (req, res) ->
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

app.post '/api/delete', session, restrict, (req, res) ->
  delPost req.body.slug, (err) ->
    if err
      return res.json 500, ok: no, err: err
    res.json ok: yes

app.post '/api/update', session, restrict, (req, res) ->
  data = req.body
  db.get "posts/#{data.slug}", (err, r) ->
    throw err if err
    for k,v of data.update when k in ['title', 'body', 'published']
      r[k] = v
    putPost r, (err) ->
      throw err if err
      res.json ok: yes

renderPost = (req, res, next, opts = {}) ->
  db.get "posts/#{req.params.slug}", (err, post) ->
    return next() if !post

    res.setHeader 'Cache-Control', 'max-age=21600' # 6 hours
    opts.post = post
    opts.model = !!opts.model
    opts.md = marked
    res.render 'text', opts

app.get '/', (req, res) ->
  last = process.hrtime()

  getPosts 'idx/published/', limit:10, reverse:yes, (err, posts) ->
    #db.view 'posts/published', { include_docs: true, descending: true, limit: 10 }, (err, posts) ->
    res.render 'index', md: marked, posts: posts

app.get '/:slug', (req, res, next) ->
  db.get "posts/#{req.params.slug}", (err, post) ->
    return next() if !post
    res.redirect 301, "/blog/#{req.params.slug}"

app.get '/:slug/edit', (req, res, next) ->
  db.get "posts/#{req.params.slug}", (err, post) ->
    return next() if !post
    res.redirect 301, "/blog/#{req.params.slug}/edit"

app.get '/blog/:slug', (req, res, next) ->
  renderPost req, res, next

app.get '/blog/:slug/edit', session, restrict, (req, res, next) ->
  renderPost req, res, next, model: true

app.get '/.well-known/webfinger', (req, res, next) ->
  resource = req.query.resource
  return next() if resource not in ['acct:me@josephg.com', 'acct:josephg@gmail.com']

  res.setHeader 'Access-Control-Allow-Origin', '*'
  res.setHeader 'Content-Type', 'application/jrd+json'
  res.setHeader 'Cache-Control', 'max-age=21600' # 6 hours
  res.end JSON.stringify
    subject: resource
    aliases: ['https://josephg.com/']
    links: [
      {rel:'avatar', type:'image/jpeg', href:'http://www.gravatar.com/avatar/555b9e9ff4c3033dd6d31ba7796d2374?s=200'}
      {rel:'homepage', type:'text/html', href:'https://josephg.com'}
      {rel:'blog', type:'text/html', href:'https://josephg.com'}
      {
        rel:'public-key'
        type:'text/plain'
        href:'http://josephg.com/josephg.key'
        properties:
          fingerprint: 'B0A4 EB55 915D 736A FE03  5584 82CD B632 8A02 DEA6'
          algorithm: 'rsa'
      }
    ]



#?resource=acct:pithy.example@gmail.com

port = process.argv[2] ? 8080
app.listen port
console.log "Listening on http://localhost:#{port}"
