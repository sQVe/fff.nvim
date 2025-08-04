--- @return string
local function get_lib_extension()
  if jit.os:lower() == 'mac' or jit.os:lower() == 'osx' then return '.dylib' end
  if jit.os:lower() == 'windows' then return '.dll' end
  return '.so'
end

-- search for the lib in both debug and release directories with and without the lib prefix
-- since MSVC doesn't include the prefix
local base_path = debug.getinfo(1).source:match('@?(.*/)')
package.cpath = package.cpath
  -- Release build paths.
  .. ';'
  .. base_path
  .. '../../../target/release/lib?'
  .. get_lib_extension()
  .. ';'
  .. base_path
  .. '../../../target/release/?'
  .. get_lib_extension()
  -- Debug build paths.
  .. ';'
  .. base_path
  .. '../../../target/debug/lib?'
  .. get_lib_extension()
  .. ';'
  .. base_path
  .. '../../../target/debug/?'
  .. get_lib_extension()

return require('fff_nvim')
