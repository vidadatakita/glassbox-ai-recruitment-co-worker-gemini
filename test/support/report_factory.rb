# Builders for the feature 08 (screening report) tests. Every name, CV and figure is INVENTED.
module ReportFactory
  # A complete, well-formed report block; quotes are verbatim lines of ScreeningFactory::FIXTURE_CV.
  def report_block(**overrides)
    {
      last_position: { text: "Admin Gudang, PT Logistik Makmur", quote: "Admin Gudang di PT Logistik Makmur" },
      education: { text: "D3 Manajemen Logistik", quote: "D3 Manajemen Logistik" },
      recent_experience: { text: "Mengelola stok gudang.", quote: "Mengelola stok 1.200 SKU" },
      strengths: [{ claim: "Terbiasa dengan stok besar", quote: "Mengelola stok 1.200 SKU" }],
      blind_spots: [{ claim: "Belum terlihat memimpin tim", quote: "kutipan yang tidak ada di CV" }],
      tolerance_risks: [],
      credibility_value: [{ claim: "Excel kuat", quote: "Microsoft Excel tingkat lanjut" }],
      label_proposal: "pertimbangkan", label_reason: "Syarat wajib terpenuhi."
    }.merge(overrides)
  end

  # Screens one invented applicant through the real pipeline (FakeGemini at the HTTP boundary) and
  # returns the S1 participation. criteria: override the judgements; report: nil for no block.
  def screened_applicant!(job, name:, report: report_block, criteria: nil, fake: ScreeningFactory::FakeGemini.new)
    text = JSON.generate({ criteria: criteria || criteria_for(job), protected_attribute_seen: false,
                           protected_attribute_categories: [], report: }.compact)
    participation = nil
    with_ai(fake) do
      fake.push(gemini_message(nil, text:))
      participation = apply_with_cv!(job, name:)
      # D51: a named reviewer releases the held CV ("Kirim ke AI") before the call (shared helper).
      screen_and_release!
    end
    participation.reload
  end
end
