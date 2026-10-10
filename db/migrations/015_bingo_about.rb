Sequel.migration do
  change do
    # Optional prose for the datacenter page, per locale. No fallback to ru:
    # Russian text on the en page would be worse than none.
    %w[ru en uk].each { |l| add_column :bingo_datacenters, :"about_#{l}", String, text: true }
  end
end
