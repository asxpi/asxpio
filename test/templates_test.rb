require_relative 'test_helper'

# A template with unbalanced <% end %> only fails when that page is
# rendered; compile every view up front so CI catches it regardless.
class TemplatesTest < Minitest::Test
  Dir[File.join(__dir__, '..', 'views', '**', '*.erb')].each do |path|
    name = path.sub(%r{.*/views/}, '').tr('/.', '__')
    define_method("test_compiles_#{name}") do
      tmpl = Tilt::ErubiTemplate.new(path, escape_html: true)
      tmpl.send(:compiled_method, [], Object) # raises SyntaxError if broken
    end
  end
end
