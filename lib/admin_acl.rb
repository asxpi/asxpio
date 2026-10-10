# Which permission an /admin request needs. Every admin path must map to
# an area (or be public/open); unmapped paths are superuser-only, and a
# test fails if any registered route is unmapped.
#
#   GET/HEAD                    → read  (except …/new and …/duplicate: write)
#   POST …/delete, …/disable    → delete
#   any other non-GET           → write
module AdminACL
  RULES = [
    [%r{\A/admin/(invoices|gel-rate|crypto-rate)(/|\z)}, 'invoices'],
    [%r{\A/admin/bingo(/|\z)},                           'bingo'],
    [%r{\A/admin/(users|audit)(/|\z)},                   'users'],
  ].freeze

  module_function

  def area_for(path)
    RULES.find { |re, _| path.match?(re) }&.last
  end

  def perm_for(method, path)
    get = %w[GET HEAD].include?(method)
    return 'delete' if !get && path.match?(%r{/(delete|disable)\z})
    return 'write'  if !get || path.match?(%r{/(new|duplicate)\z})
    'read'
  end

  def allowed?(user, method, path)
    return true if user.superuser || path.match?(AdminAuth::OPEN)
    area = area_for(path) or return false
    user.can?(area, perm_for(method, path))
  end
end
