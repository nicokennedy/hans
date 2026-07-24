require "test_helper"

class Notifications::WhatsappLinkTest < ActiveSupport::TestCase
  test "builds a wa.me url using the configured number" do
    with_whatsapp_number("5492235275412") do
      url = Notifications::WhatsappLink.build("Hola")
      assert_equal "https://wa.me/5492235275412?text=Hola", url
    end
  end

  test "url-encodes special characters, accents and line breaks in the text" do
    with_whatsapp_number("5492235275412") do
      text = "Café ñ & Entrega: 25/07/2026\nLínea 2"
      url = Notifications::WhatsappLink.build(text)

      assert url.start_with?("https://wa.me/5492235275412?text=")
      assert_includes url, ERB::Util.url_encode(text)
      assert_no_match(/[ñáéíóú]/i, url.split("text=").last)
    end
  end

  test "returns nil (not a broken link) when the environment variable is missing" do
    with_whatsapp_number(nil) do
      assert_nil Notifications::WhatsappLink.build("Hola")
    end
  end

  test "returns nil when the environment variable is blank" do
    with_whatsapp_number("") do
      assert_nil Notifications::WhatsappLink.build("Hola")
    end
  end

  test "configured? reflects whether the environment variable is present" do
    with_whatsapp_number("5492235275412") { assert Notifications::WhatsappLink.configured? }
    with_whatsapp_number(nil) { assert_not Notifications::WhatsappLink.configured? }
  end

  test "never falls back to the old hardcoded number" do
    with_whatsapp_number("5492235275412") do
      url = Notifications::WhatsappLink.build("Hola")
      assert_no_match "5492914168790", url
    end
  end

  private

  def with_whatsapp_number(value)
    original = ENV["WHATSAPP_OBRADOR_NUMBER"]
    ENV["WHATSAPP_OBRADOR_NUMBER"] = value
    yield
  ensure
    ENV["WHATSAPP_OBRADOR_NUMBER"] = original
  end
end
