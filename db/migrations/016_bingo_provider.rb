Sequel.migration do
  up do
    # Company grouping for the per-provider cards (Bingo::PROVIDERS slugs).
    # Backfilled from the free-text operator; Datacenter#before_create keeps
    # new rows filled the same way (Bingo.guess_provider).
    add_column :bingo_datacenters, :provider, String
    {
      'yandex' => %w[Яндекс%], 'ixcellerate' => %w[IXcellerate%], 'rtk' => %w[РТК-ЦОД%],
      'atomdata' => %w[Атомдата% Росатом%], 'datapro' => %w[DataPro%], 'selectel' => %w[Selectel%],
      'mws' => %w[MWS% МТС%], 'keypoint' => ['Key Point%'], '3data' => %w[3data%], 'sber' => %w[Сбер%],
      'megafon' => %w[МегаФон%], 'datahouse' => %w[DataHouse%], 'oxygen' => %w[OXYGEN%], 'linx' => %w[Linx%],
      'cloudx' => ['Cloud X%'], 'nkgroup' => ['NK Group%'], 'goznak' => %w[Гознак%]
    }.each do |slug, patterns|
      patterns.each do |pat|
        self[:bingo_datacenters].where(provider: nil).where(Sequel.ilike(:operator, pat)).update(provider: slug)
      end
    end
  end

  down do
    drop_column :bingo_datacenters, :provider
  end
end
