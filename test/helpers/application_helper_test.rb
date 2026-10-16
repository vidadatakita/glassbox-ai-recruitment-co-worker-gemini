require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "the ad renders headings, paragraphs and lists, and escapes markup" do
    html = ad_html("Tentang posisi ini\nKami mencari staf.\n\nYang kami cari\n- Excel <b>mahir</b>\n- Teliti\nPenempatan\n- Bekasi")
    assert_equal "<h3>Tentang posisi ini</h3><p>Kami mencari staf.</p><h3>Yang kami cari</h3>" \
                 "<ul><li>Excel &lt;b&gt;mahir&lt;/b&gt;</li><li>Teliti</li></ul><h3>Penempatan</h3><ul><li>Bekasi</li></ul>", html
  end
end
