Path = require 'path'

home = if process.platform == 'win32' then process.env.USERPROFILE else process.env.HOME

# Copyright (c) George Ogata
# code from tab-switcher
isUnder = (dir, path) ->
  Path.relative(path, dir).startsWith('..')

# Copyright (c) George Ogata
# code from tab-switcher
projectRelativePath = (path) ->
  path = Path.dirname(path)
  [root, relativePath] = atom.project.relativizePath(path)
  if root
    if atom.project.getPaths().length > 1
      relativePath = Path.basename(root) + Path.sep + relativePath
    relativePath
  else if home and isUnder(home, path)
    '~' + Path.sep + Path.relative(home, path)
  else
    path

projectRelativeFilename = (path) ->
  p = projectRelativePath path
  f = Path.basename(path)
  return p + Path.sep + f

exports.projectRelativeFilename = projectRelativeFilename
