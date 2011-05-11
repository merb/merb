module Merb
  module Generators

    VERSION = '1.2.0'.freeze

    # Duplicated here (originally in merb_datamapper)
    # This is currently the easiest way to get at the
    # datamapper version requirements, and still seems
    # better than specifying the datamapper version in
    # merb-core itself.
    DM_VERSION_REQUIREMENT = '~> 1.0'.freeze

    # Necessary to supply builtin support for do_sqlite3
    DO_VERSION_REQUIREMENT = '~> 1.0'.freeze

    # merb-auth has separate versioning scheme as well
    AUTH_VERSION_REQUIREMENT = '~> 1.0'.freeze
  end
end
