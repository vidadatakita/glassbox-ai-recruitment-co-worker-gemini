# Six sample jobs for the job form (feature 03; D49: "Sample seed jobs follow the house Golongan
# template: Operator G2, Team Leader G3, Supervisor G4, Manager G6, General Manager G7, Direktur G8").
#
# EVERYTHING HERE IS INVENTED DEMO CONTENT for the fictional "PT Contoh Maju Bersama": titles,
# activities, requirements, competencies, and especially the SALARY BANDS and THRESHOLDS, which are
# plausible-looking demo values, not market data and not house defaults (no threshold default
# exists in the spec). Packages follow blueprint §7.1; stage weights are the concept-brief §4.1
# defaults re-normalised (Briefs::StagePlan.default_weights).
#
# Each job is written through the same services as the screens (Briefs::SaveStep, Briefs::Complete),
# so a seed that breaks a brief rule fails loudly instead of planting an invalid demo job.
# Idempotent: a job that already exists with a complete brief is left alone. The two older demo
# jobs ("Staf Admin Gudang", "Staf Gudang Shift Malam") are never read or written here.
require_relative "demo_test_cases"

module DemoJobs
  # Demo thresholds per stage (0-100). Invented for the demo, see the header.
  THRESHOLDS = { "S1" => 60, "S2" => 60, "S3" => 65, "S4" => 60, "S5" => 70 }.freeze

  JOBS = [
    {
      title: "Operator Produksi", golongan: 2, headcount: 6, employment_type: "kontrak_pkwt", package: 3,
      salary: [5_300_000, 5_900_000], show_salary: true, placements: %w[Bekasi Karawang], relocation: "diutamakan", work_arrangement: "onsite",
      success_90d: "Menjalankan satu lini mesin pengemasan secara mandiri selama satu shift penuh, dengan tingkat reject di bawah 2% dan tanpa insiden keselamatan.",
      activities: [
        ["Menyiapkan mesin dan bahan sebelum shift dimulai", "Checklist persiapan mesin terisi dan ditandatangani", 15],
        ["Mengoperasikan mesin pengemasan sesuai instruksi kerja", "Jumlah kemasan sesuai target per jam", 40],
        ["Memeriksa mutu hasil kemasan secara berkala", "Catatan pemeriksaan mutu setiap 30 menit", 15],
        ["Mencatat hasil produksi dan waktu henti mesin", "Laporan produksi akhir shift", 10],
        ["Membersihkan area dan mesin sesuai standar 5R", "Area kerja lolos pemeriksaan 5R", 10],
        ["Melaporkan kerusakan atau kekurangan bahan kepada kepala regu", "Laporan kendala tercatat di buku shift", 10]
      ],
      wajib: [
        ["Pendidikan minimal SMA/SMK", "Ijazah SMA/SMK tercantum di CV", "Apakah Anda lulusan SMA/SMK atau sederajat?"],
        ["Bersedia bekerja dalam tiga shift bergilir", "Pernyataan ketersediaan shift", "Apakah Anda bersedia bekerja shift bergilir, termasuk shift malam?"],
        ["Pengalaman kerja di area produksi minimal 6 bulan", "Riwayat kerja di pabrik atau area produksi", nil]
      ],
      sebaiknya: [
        ["Pengalaman mengoperasikan mesin pengemasan atau pengisian", "Nama mesin atau lini disebut di riwayat kerja", 50],
        ["Memahami dasar 5R atau K3", "Pelatihan 5R/K3 tercantum di CV", 30],
        ["Tinggal di sekitar Bekasi atau Karawang", "Alamat domisili di CV", 20]
      ],
      nilai_tambah: [["Sertifikat operator dari BNSP", "Nomor sertifikat di CV"]],
      competencies: [
        ["Pengetahuan instruksi kerja mesin", "L1", "S2", "Salah menjawab urutan langkah pengoperasian dasar", "Menjawab urutan langkah dengan benar", "Menjawab benar dan menjelaskan titik periksa keselamatan tiap langkah", nil],
        ["Mengoperasikan mesin sesuai standar", "L4", "S2", "Hasil kerja sampel perlu diulang", "Hasil kerja sampel sesuai standar", "Hasil sesuai standar sejak pertama dan lebih cepat dari waktu baku", nil],
        ["Kejujuran melaporkan selisih bahan dan kesalahan sendiri", "I", "S3", "Contoh yang diceritakan menunjukkan selisih disembunyikan", "Melaporkan selisih ketika ditanya atasan", "Melaporkan selisih tanpa diminta, segera, dan ikut memperbaiki cara kerja",
         "Ceritakan saat Anda menemukan bahan lebih atau kurang dari catatan. Apa yang Anda lakukan, dan kapan Anda melaporkannya?"],
        ["Membaca masalah mesin sederhana", "L2", "S3", "Hanya menyebut mesin berhenti tanpa penyebab", "Menemukan penyebab dengan bantuan pertanyaan", "Menemukan penyebab sendiri dan menyebut dampaknya ke lini lain",
         "Ceritakan satu kali mesin Anda berhenti mendadak. Apa penyebabnya dan bagaimana Anda tahu?"],
        ["Kesiapan bekerja dalam tim shift", "L4", "S5", "Tidak dapat memberi contoh kerja sama serah terima shift", "Memberi contoh serah terima shift yang rapi", "Memberi contoh serah terima yang mencegah masalah di shift berikutnya",
         "Bagaimana Anda menyerahkan pekerjaan ke shift berikutnya? Berikan contoh."]
      ]
    },
    {
      title: "Team Leader Gudang", golongan: 3, headcount: 2, employment_type: "tetap_pkwtt", package: 3,
      salary: [6_800_000, 8_200_000], show_salary: true, placements: %w[Cikarang], relocation: "tidak_perlu", work_arrangement: "onsite",
      success_90d: "Memimpin regu gudang 8 orang pada satu shift dengan akurasi stok hasil cycle count minimal 99% dan pengiriman tepat waktu minimal 97%.",
      activities: [
        ["Membagi tugas regu pada awal shift", "Daftar pembagian tugas harian", 15],
        ["Mengawasi penerimaan dan penyimpanan barang", "Dokumen penerimaan cocok dengan fisik", 25],
        ["Mengawasi pengambilan dan pengiriman pesanan", "Pesanan terkirim sesuai jadwal", 25],
        ["Menjalankan cycle count harian", "Laporan selisih stok harian", 15],
        ["Melatih anggota regu baru", "Anggota baru bekerja mandiri dalam dua minggu", 10],
        ["Melaporkan kinerja regu kepada penyelia", "Laporan mingguan kinerja regu", 10]
      ],
      wajib: [
        ["Pengalaman di gudang minimal 2 tahun", "Riwayat kerja gudang dengan masa kerja", "Apakah Anda memiliki pengalaman kerja di gudang minimal 2 tahun?"],
        ["Pernah memimpin regu atau menjadi koordinator", "Jabatan koordinator atau kepala regu di CV", "Apakah Anda pernah memimpin regu kerja, minimal 3 orang?"],
        ["Terbiasa dengan sistem stok berbasis komputer", "Nama sistem WMS/ERP di CV", nil]
      ],
      sebaiknya: [
        ["Pengalaman cycle count atau stock opname", "Kegiatan stock opname disebut di CV", 40],
        ["Pendidikan D3 atau lebih tinggi", "Ijazah D3/S1 di CV", 20],
        ["Memiliki SIO forklift", "Nomor SIO di CV", 40]
      ],
      nilai_tambah: [["Pengalaman gudang FMCG", "Nama perusahaan FMCG di riwayat kerja"]],
      competencies: [
        ["Pengetahuan alur FIFO/FEFO dan dokumen gudang", "L1", "S2", "Tidak dapat menjelaskan FIFO/FEFO", "Menjelaskan FIFO/FEFO dengan benar", "Menjelaskan dan memberi contoh kapan FEFO harus didahulukan", nil],
        ["Menemukan penyebab selisih stok", "L2", "S3", "Menyebut selisih tanpa penyebab", "Menemukan penyebab dengan bantuan pertanyaan", "Menemukan penyebab sendiri dan menyebut proses lain yang terdampak",
         "Ceritakan selisih stok terbesar yang pernah Anda temukan. Bagaimana Anda menelusuri penyebabnya?"],
        ["Menyusun rencana kerja regu", "L4", "S2", "Rencana kerja sampel tidak memenuhi target", "Rencana memenuhi target dan jumlah orang", "Rencana memenuhi target dengan cadangan orang untuk lonjakan pesanan", nil],
        ["Melatih anggota regu", "L5", "S5", "Belum pernah melatih orang lain", "Pernah menunjukkan cara kerja kepada anggota baru", "Dapat menyebut anggota yang kini bekerja mandiri berkat pelatihannya",
         "Siapa yang pernah Anda latih, dan apa yang sekarang dapat ia kerjakan sendiri?"],
        ["Kejujuran atas selisih stok", "I", "S3", "Contoh menunjukkan selisih ditutupi", "Melaporkan selisih ketika diminta", "Melaporkan selisih segera tanpa diminta dan mengusulkan perbaikan",
         "Ceritakan saat stok fisik lebih banyak dari catatan. Apa yang Anda lakukan?"]
      ]
    },
    {
      title: "Supervisor Produksi", golongan: 4, headcount: 1, employment_type: "tetap_pkwtt", package: 4,
      salary: [9_500_000, 12_500_000], show_salary: false, placements: %w[Karawang], relocation: "wajib", work_arrangement: "onsite",
      success_90d: "Menjalankan dua lini produksi dengan OEE minimal 75%, rencana produksi mingguan tercapai minimal 95%, dan tanpa kecelakaan kerja hilang waktu.",
      activities: [
        ["Menyusun jadwal produksi harian dari rencana mingguan", "Jadwal produksi harian disetujui", 15],
        ["Mengawasi jalannya dua lini produksi", "Target output per shift tercapai", 30],
        ["Memimpin rapat awal shift dan menyelesaikan kendala", "Notulen kendala dan tindak lanjut", 15],
        ["Menganalisis waktu henti dan reject", "Laporan analisis penyebab mingguan", 15],
        ["Melatih dan menilai kepala regu", "Penilaian kepala regu per bulan", 10],
        ["Memastikan penerapan K3 di area produksi", "Temuan K3 ditutup tepat waktu", 15]
      ],
      wajib: [
        ["Pendidikan minimal D3 teknik atau manajemen industri", "Ijazah D3/S1 jurusan terkait", "Apakah Anda lulusan minimal D3 teknik atau manajemen industri?"],
        ["Pengalaman sebagai supervisor produksi minimal 2 tahun", "Jabatan supervisor dan masa kerja di CV", "Apakah Anda memiliki pengalaman sebagai supervisor produksi minimal 2 tahun?"],
        ["Memahami perhitungan OEE", "Proyek atau pencapaian OEE disebut di CV", nil]
      ],
      sebaiknya: [
        ["Pengalaman menerapkan lean atau kaizen", "Proyek kaizen dengan hasil di CV", 40],
        ["Sertifikat Ahli K3 Umum", "Nomor sertifikat K3 di CV", 30],
        ["Pengalaman di industri pengemasan atau makanan", "Nama perusahaan sejenis di CV", 30]
      ],
      nilai_tambah: [["Menguasai analisis data dengan spreadsheet tingkat lanjut", "Pelatihan atau proyek analisis data"]],
      competencies: [
        ["Pengetahuan standar produksi dan K3", "L1", "S2", "Salah menjawab standar dasar K3", "Menjawab standar dengan benar", "Menjawab benar dan mengaitkan standar dengan risiko di lini", nil],
        ["Analisis penyebab waktu henti", "L2", "S3", "Menyebut gejala tanpa penyebab", "Menemukan penyebab dengan bantuan", "Menemukan penyebab akar sendiri dan menyebut proses lain yang terdampak",
         "Ceritakan masalah waktu henti yang Anda telusuri sampai akar penyebabnya. Apa hasilnya?"],
        ["Menolak instruksi yang membahayakan mutu atau keselamatan", "L3", "S5", "Mengikuti instruksi tanpa menilai akibatnya", "Menyampaikan keberatan saat masalah sudah jelas", "Melihat masalah lebih awal, menyampaikan dengan data, lalu menerima keputusan akhir",
         "Ceritakan saat Anda tidak setuju dengan instruksi atasan tentang produksi. Apa yang Anda lakukan dan apa hasilnya?"],
        ["Menyusun jadwal produksi", "L4", "S2", "Jadwal sampel tidak memenuhi kapasitas", "Jadwal memenuhi kapasitas dan pesanan", "Jadwal memenuhi kapasitas dan menyisakan waktu perawatan terencana", nil],
        ["Mengembangkan kepala regu", "L5", "S5", "Belum pernah membina bawahan", "Pernah membimbing kepala regu pada satu tugas", "Dapat menyebut kepala regu yang kini memimpin shift sendiri berkat bimbingannya",
         "Siapa yang pernah Anda kembangkan menjadi pemimpin regu, dan apa yang kini ia kerjakan sendiri?"],
        ["Kejujuran atas angka produksi", "I", "S3", "Contoh menunjukkan angka disesuaikan agar target terlihat tercapai", "Melaporkan angka apa adanya ketika diminta", "Melaporkan kekurangan target lebih awal tanpa diminta dan mengusulkan perbaikan",
         "Ceritakan saat target produksi tidak tercapai. Bagaimana Anda melaporkannya?"]
      ]
    },
    {
      title: "Manager HR", golongan: 6, headcount: 1, employment_type: "tetap_pkwtt", package: 4,
      salary: [18_000_000, 25_000_000], show_salary: false, placements: %w[Bekasi], relocation: "tidak_perlu", work_arrangement: "hybrid",
      success_90d: "Menyelesaikan peta jabatan dan Golongan untuk seluruh karyawan, menurunkan waktu pengisian lowongan staf menjadi di bawah 30 hari, dan menjalankan penggajian tanpa koreksi.",
      activities: [
        ["Menyusun dan menjalankan rencana kebutuhan tenaga kerja", "Rencana tenaga kerja tahunan disetujui direksi", 20],
        ["Mengelola rekrutmen dan seleksi", "Lowongan terisi sesuai target waktu", 20],
        ["Mengelola penggajian dan kepatuhan ketenagakerjaan", "Penggajian tepat waktu tanpa temuan kepatuhan", 20],
        ["Menangani hubungan industrial dan serikat pekerja", "Perselisihan selesai secara bipartit", 15],
        ["Mengembangkan dan melatih tim HR", "Rencana pengembangan tim HR berjalan", 15],
        ["Melaporkan indikator SDM kepada direksi", "Laporan bulanan indikator SDM", 10]
      ],
      wajib: [
        ["Pendidikan minimal S1 psikologi, hukum, atau manajemen", "Ijazah S1 jurusan terkait", "Apakah Anda lulusan minimal S1 psikologi, hukum, atau manajemen?"],
        ["Pengalaman sebagai manajer HR minimal 3 tahun", "Jabatan manajer HR dan masa kerja di CV", "Apakah Anda memiliki pengalaman sebagai manajer HR minimal 3 tahun?"],
        ["Memahami UU Ketenagakerjaan dan aturan turunannya", "Pengalaman menyusun peraturan perusahaan atau PKB", "Apakah Anda pernah menyusun peraturan perusahaan atau PKB?"]
      ],
      sebaiknya: [
        ["Pengalaman di perusahaan manufaktur dengan lebih dari 300 karyawan", "Jumlah karyawan perusahaan di CV", 40],
        ["Pengalaman menyusun struktur Golongan dan skala upah", "Proyek struktur dan skala upah di CV", 35],
        ["Sertifikasi profesi SDM dari BNSP", "Nomor sertifikat di CV", 25]
      ],
      nilai_tambah: [["Pengalaman memimpin implementasi sistem HRIS", "Nama proyek HRIS di CV"]],
      competencies: [
        ["Memahami hubungan kebijakan SDM dengan biaya dan produktivitas", "L2", "S3", "Menjelaskan kebijakan tanpa dampaknya", "Menjelaskan dampak dengan bantuan pertanyaan", "Menjelaskan dampak ke biaya dan produktivitas dengan angka tanpa diminta",
         "Ceritakan kebijakan SDM yang Anda ubah. Apa dampaknya terhadap biaya dan produktivitas?"],
        ["Menilai dan menolak keputusan SDM yang berisiko hukum", "L3", "S5", "Menjalankan permintaan tanpa menilai risiko", "Mengingatkan risiko ketika sudah jelas", "Melihat risiko lebih awal, menyampaikan dengan dasar hukum, dan menawarkan jalan lain",
         "Ceritakan saat Anda menolak atau mengubah permintaan direksi tentang karyawan. Apa dasarnya dan apa hasilnya?"],
        ["Mengembangkan tim HR", "L5", "S5", "Belum pernah mengembangkan bawahan", "Pernah membimbing staf pada satu tugas", "Dapat menyebut staf yang kini memegang fungsi sendiri berkat bimbingannya",
         "Siapa di tim Anda yang kini memegang fungsi sendiri karena Anda kembangkan? Apa yang dulu belum dapat ia lakukan?"],
        ["Kejujuran atas data SDM dan anggaran", "I", "S3", "Contoh menunjukkan data disesuaikan agar terlihat baik", "Melaporkan data apa adanya ketika diminta", "Melaporkan kesalahan sendiri lebih awal tanpa diminta dan memperbaiki prosesnya",
         "Ceritakan kesalahan dalam penggajian atau data karyawan yang pernah terjadi di bawah Anda. Bagaimana Anda menanganinya?"],
        ["Pengetahuan regulasi ketenagakerjaan", "L1", "S2", "Salah menjawab ketentuan dasar PKWT", "Menjawab ketentuan dengan benar", "Menjawab benar dan menunjuk pasal serta perubahannya", nil]
      ]
    },
    {
      title: "General Manager Operasional", golongan: 7, headcount: 1, employment_type: "tetap_pkwtt", package: 5,
      salary: [35_000_000, 45_000_000], show_salary: false, placements: %w[Karawang Bekasi], relocation: "wajib", work_arrangement: "onsite",
      success_90d: "Menyusun rencana operasional tahunan yang disetujui direksi, menurunkan biaya produksi per unit 3%, dan menetapkan ritme rapat kinerja mingguan di seluruh fungsi operasional.",
      activities: [
        ["Menyusun rencana dan anggaran operasional", "Rencana dan anggaran tahunan disetujui direksi", 20],
        ["Memimpin manajer produksi, gudang, dan pemeliharaan", "Sasaran setiap fungsi tercapai", 25],
        ["Mengendalikan biaya produksi dan logistik", "Biaya per unit sesuai anggaran", 20],
        ["Memimpin program perbaikan berkelanjutan", "Proyek perbaikan dengan penghematan terukur", 15],
        ["Mengembangkan calon pengganti manajer", "Calon pengganti untuk setiap fungsi", 10],
        ["Melaporkan kinerja operasional kepada direksi", "Laporan kinerja bulanan", 10]
      ],
      wajib: [
        ["Pendidikan minimal S1 teknik atau manajemen", "Ijazah S1 jurusan terkait", "Apakah Anda lulusan minimal S1 teknik atau manajemen?"],
        ["Pengalaman memimpin beberapa fungsi operasional minimal 5 tahun", "Jabatan kepala divisi atau GM di CV", "Apakah Anda pernah memimpin beberapa fungsi operasional sekaligus minimal 5 tahun?"],
        ["Pengalaman mengelola anggaran operasional", "Besaran anggaran yang dikelola di CV", nil]
      ],
      sebaiknya: [
        ["Pengalaman di industri manufaktur barang konsumsi", "Nama perusahaan sejenis di CV", 40],
        ["Pengalaman memimpin program lean di tingkat pabrik", "Hasil program lean di CV", 35],
        ["Pendidikan S2", "Ijazah S2 di CV", 25]
      ],
      nilai_tambah: [["Pengalaman membuka pabrik atau lini baru", "Proyek pembukaan pabrik di CV"]],
      competencies: [
        ["Memahami keterkaitan produksi, gudang, dan biaya", "L2", "S3", "Melihat masalah per fungsi saja", "Menghubungkan fungsi dengan bantuan pertanyaan", "Menghubungkan fungsi dan biaya sendiri dengan contoh angka",
         "Ceritakan keputusan di satu fungsi yang berdampak ke fungsi lain. Bagaimana Anda melihatnya?"],
        ["Menilai rencana dan menolak target yang tidak masuk akal", "L3", "S5", "Menerima target tanpa menilai", "Menyampaikan keberatan ketika masalah sudah jelas", "Melihat masalah lebih awal, berargumen dengan data, dan menerima keputusan akhir",
         "Ceritakan saat Anda menolak target atau rencana dari direksi. Apa data Anda dan apa hasilnya?"],
        ["Mengembangkan calon pengganti", "L5", "S5", "Belum menyiapkan pengganti", "Pernah menyiapkan satu pengganti", "Dapat menyebut beberapa manajer yang kini memimpin fungsi berkat pembinaannya",
         "Siapa yang Anda siapkan sebagai pengganti, dan jabatan apa yang kini ia pegang?"],
        ["Kejujuran atas kinerja dan anggaran", "I", "S3", "Contoh menunjukkan angka disesuaikan", "Melaporkan apa adanya ketika diminta", "Melaporkan penyimpangan anggaran lebih awal tanpa diminta dan memperbaiki prosesnya",
         "Ceritakan saat anggaran Anda melampaui rencana. Bagaimana dan kapan Anda melaporkannya?"],
        ["Merancang sistem kerja operasional", "L4", "S5", "Tidak dapat memberi contoh sistem yang dirancang", "Pernah merancang satu prosedur yang berjalan", "Merancang sistem yang berjalan tanpa dirinya dan memberi hasil terukur",
         "Ceritakan sistem kerja yang Anda rancang dan masih berjalan setelah Anda pindah."]
      ]
    },
    {
      title: "Direktur Operasional", golongan: 8, headcount: 1, employment_type: "tetap_pkwtt", package: 5,
      salary: [60_000_000, 80_000_000], show_salary: false, placements: %w[Jakarta], relocation: "tidak_perlu", work_arrangement: "hybrid",
      success_90d: "Menetapkan strategi operasional tiga tahun yang disetujui pemegang saham, dengan sasaran biaya, mutu, dan keselamatan yang diturunkan ke setiap fungsi.",
      activities: [
        ["Menetapkan strategi dan sasaran operasional", "Strategi tiga tahun disetujui pemegang saham", 25],
        ["Memimpin GM dan kepala divisi operasional", "Sasaran divisi tercapai", 20],
        ["Mengambil keputusan investasi mesin dan fasilitas", "Keputusan investasi dengan kajian kelayakan", 20],
        ["Mengelola risiko operasional dan kepatuhan", "Daftar risiko diperbarui setiap kuartal", 15],
        ["Membangun budaya keselamatan dan mutu", "Indikator keselamatan dan mutu membaik", 10],
        ["Melaporkan kepada direksi dan pemegang saham", "Laporan kuartalan", 10]
      ],
      wajib: [
        ["Pengalaman sebagai direktur atau GM operasional minimal 8 tahun", "Jabatan dan masa kerja di CV", "Apakah Anda memiliki pengalaman sebagai direktur atau GM operasional minimal 8 tahun?"],
        ["Pengalaman memimpin organisasi lebih dari 500 orang", "Jumlah bawahan di CV", "Apakah Anda pernah memimpin organisasi lebih dari 500 orang?"],
        ["Pendidikan minimal S1", "Ijazah S1 di CV", nil]
      ],
      sebaiknya: [
        ["Pengalaman di perusahaan manufaktur multi-pabrik", "Jumlah pabrik di CV", 50],
        ["Pengalaman memimpin transformasi operasional", "Hasil transformasi di CV", 30],
        ["Pendidikan S2 manajemen atau teknik", "Ijazah S2 di CV", 20]
      ],
      nilai_tambah: [["Pengalaman sebagai anggota direksi perusahaan terbuka", "Jabatan direksi di CV"]],
      competencies: [
        ["Memahami rantai nilai operasional dan dampaknya ke laba", "L2", "S3", "Menjelaskan operasi tanpa kaitan dengan laba", "Mengaitkan operasi dengan laba dengan bantuan", "Mengaitkan sendiri setiap keputusan operasional dengan laba dan risiko",
         "Ceritakan keputusan operasional yang paling besar dampaknya ke laba. Bagaimana Anda menghitungnya?"],
        ["Menilai dan menolak keputusan strategis yang keliru", "L3", "S5", "Tidak memberi contoh keputusan yang ditolak", "Menyampaikan keberatan ketika masalah sudah jelas", "Melihat masalah lebih awal, berargumen dengan data, dan menerima keputusan akhir",
         "Ceritakan saat Anda tidak setuju dengan keputusan pemegang saham atau dewan. Apa yang Anda lakukan?"],
        ["Membangun pemimpin di bawahnya", "L5", "S5", "Belum menyiapkan pemimpin pengganti", "Pernah menyiapkan satu pengganti", "Dapat menyebut beberapa pemimpin yang kini memimpin divisi berkat pembinaannya",
         "Siapa pemimpin yang Anda bangun, dan apa yang kini mereka pimpin sendiri?"],
        ["Kejujuran atas kinerja dan risiko perusahaan", "I", "S3", "Contoh menunjukkan risiko ditutupi dari dewan", "Melaporkan risiko ketika diminta", "Melaporkan risiko dan kesalahan sendiri lebih awal tanpa diminta",
         "Ceritakan risiko besar yang Anda laporkan ke dewan sebelum diminta. Apa yang terjadi kemudian?"]
      ]
    }
  ].freeze

  module_function

  def run(company:, actor:)
    JOBS.map { |data| seed(data, company:, actor:) }
  end

  def seed(data, company:, actor:)
    job = Job.find_by(title: data[:title], client_company: company)
    # Feature 07 (D60): a job completed before the technical test existed gets its approved demo
    # test here; DemoTestCases.ensure! writes nothing when one is already approved.
    return job.tap { DemoTestCases.ensure!(job, hr: actor) } if job&.brief_complete?

    job ||= Job.new(client_company: company)
    steps(data).each do |step, params|
      result = Briefs::SaveStep.call(job:, step:, params:, actor:)
      raise "seed #{data[:title]} step #{step} refused: #{result.errors.join(' | ')}" unless result.ok?
    end
    DemoTestCases.ensure!(job.reload, hr: actor) # D60: packages 3+ complete only with an approved test
    result = Briefs::Complete.call(job: job.reload, actor:)
    raise "seed #{data[:title]} not complete: #{result.problems.map(&:message).join(' | ')}" unless result.ok?

    job.reload
  end

  def steps(data)
    {
      "1" => { title: data[:title], golongan: data[:golongan].to_s, headcount: data[:headcount].to_s,
               employment_type: data[:employment_type], confidential: "0" },
      "2" => { success_90d: data[:success_90d],
               activities: indexed(data[:activities].map { |d, o, s| { description: d, output: o, share_percent: s.to_s } }) },
      "3" => { salary_min: data[:salary][0].to_s, salary_max: data[:salary][1].to_s, show_salary: data[:show_salary] ? "1" : "0",
               placements: data[:placements], relocation: data[:relocation], work_arrangement: data[:work_arrangement],
               requirements: indexed(requirements(data)) },
      "4" => { package: data[:package].to_s, stage_plan: stage_plan(data[:package]),
               competencies: indexed(data[:competencies].map { |n, l, s, a1, a3, a5, q| { name: n, layer: l, stage_code: s, anchor_1: a1, anchor_3: a3, anchor_5: a5, questions: q } }) }
    }
  end

  def requirements(data)
    data[:wajib].map { |t, e, k| { tier: "wajib", text: t, cv_evidence: e, knockout: k } } +
      data[:sebaiknya].map { |t, e, w| { tier: "sebaiknya", text: t, cv_evidence: e, weight: w.to_s } } +
      data[:nilai_tambah].map { |t, e| { tier: "nilai_tambah", text: t, cv_evidence: e } }
  end

  def stage_plan(package)
    Briefs::StagePlan.default_weights(package).to_h { |code, weight| [code, { weight: weight.to_s, threshold: THRESHOLDS.fetch(code).to_s }] }
  end

  def indexed(rows) = rows.each_with_index.to_h { |row, i| [i.to_s, row] }
end
