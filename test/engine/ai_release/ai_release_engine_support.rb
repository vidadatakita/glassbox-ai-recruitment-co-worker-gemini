# Helpers for the feature-09 test engine (AI release gate, D51 = A + B + C). Written by the test
# engine on 2026-10-10. Reuses the feature-06 engine support (FakeGemini at the HTTP boundary,
# release through the real AiReleases::Release path); its hash is in docs/test-engine/hashes-06.txt.
require_relative "../screening/screening_engine_support"

module AiReleaseEngineSupport
  include ScreeningEngineSupport

  EVIDENCE_CV = <<~CV.freeze
    PENGALAMAN KERJA
    2017 - 2024 Admin Gudang di PT Logistik Makmur, Cikarang
    Mengelola stok 1.200 SKU dengan aplikasi WMS dan stock opname bulanan.
    PENDIDIKAN
    D3 Manajemen Logistik, Politeknik Negeri Jakarta, lulus 2016
    KEAHLIAN
    Microsoft Excel tingkat lanjut, memiliki SIM C dan bersedia kerja shift
  CV

  # Applies with the AI on, stores `cv_text`, runs the jobs WITHOUT releasing. Returns
  # [participation, fake, latest release].
  def hold!(job, cv_text = EVIDENCE_CV, name: CANDIDATE_NAME, fake: FakeGemini.new)
    participation = with_ai(fake) do
      p = apply_with_cv!(job, name:)
      p.job_application.update!(cv_text:, cv_text_source: "pdf", cv_text_at: Time.current)
      drain_jobs!(release: false)
      p.reload
    end
    [participation, fake, AiRelease.latest_for(participation)]
  end

  def release!(release, user: releaser)
    AiReleases::Release.call(release:, user:, confirmed: "1", seen_sha256: release.payload_sha256)
  end

  def sent_contents(fake) = fake.parsed_bodies.map { |b| b.dig("contents", 0, "parts", 0, "text") }

  # Raw insert of an action, bypassing every service (the database must refuse what the service does).
  def raw_action!(release, actor, action: "released", sha: release.payload_sha256, note: nil)
    AiReleaseAction.insert!({ ai_release_id: release.id, action:, actor_id: actor.id, checked: true,
                              payload_sha256: sha, note:, created_at: Time.current })
  end
end
