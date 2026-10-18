module Screening
  # An INVENTED CV and rubric for the one-call check and token count. No real person; safe to send
  # to the API.
  module Sample
    CV = <<~CV.freeze
      CURRICULUM VITAE
      Nama : Contoh Kandidat Fiktif
      Tempat/Tgl Lahir : Kota Contoh, 01-01-1990
      Agama : (contoh)
      PENDIDIKAN
      D3 Manajemen Logistik, Politeknik Contoh, lulus 2012
      PENGALAMAN KERJA
      2013 - 2024 Admin Gudang di PT Contoh Logistik
      Mengelola stok 900 SKU dengan aplikasi WMS dan stock opname bulanan.
      KEAHLIAN
      Microsoft Excel (pivot table, VLOOKUP); bersedia kerja shift
    CV

    Req = Struct.new(:id, :tier, :text, :cv_evidence, :weight, :position)
    REQUIREMENTS = [
      Req.new(1, "wajib", "Pendidikan minimal D3", "Ijazah D3 atau S1 di CV", nil, 1),
      Req.new(2, "wajib", "Bersedia kerja shift", "Pernyataan bersedia shift", nil, 2),
      Req.new(3, "sebaiknya", "Pengalaman admin gudang", "Riwayat kerja di gudang", 60, 3),
      Req.new(4, "sebaiknya", "Mahir Microsoft Excel", "Keahlian Excel disebut", 40, 4),
      Req.new(5, "nilai_tambah", "Memiliki SIM C", "SIM C disebut", nil, 5)
    ].freeze

    module_function

    def rubric = Rubric.new(REQUIREMENTS)
    def redacted_cv = Redactor.call(CV, names: ["Contoh Kandidat Fiktif"]).text
  end
end
