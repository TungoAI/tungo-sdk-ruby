# frozen_string_literal: true

require_relative "test_helper"

# Operations whose response is a file: the bytes come back exactly as sent, with their name and
# content type; errors and retries are those of every other call.
class DownloadsTest < TungoTestCase
  XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  BYTES = "PK\x03\x04\x00\xFF\xFE\x80 not text \r\n\x00".b.freeze
  DISPOSITION = "attachment; filename=\"Otchet.xlsx\"; filename*=UTF-8''%D0%9E%D1%82%D1%87%D1%91%D1%82.xlsx"

  def file_response(body = BYTES, headers = {})
    { status: 200, headers: { "content-type" => XLSX }.merge(headers), body: body }
  end

  def test_a_file_is_downloaded_as_its_exact_bytes
    server.respond { |_| file_response(BYTES, "content-disposition" => DISPOSITION, "x-request-id" => "req_file") }
    file = client(company_id: "co_1").proposals.export("P-000123", format: "pdf")

    assert_instance_of Tungo::DownloadedFile, file
    assert_equal BYTES, file.content
    assert_equal Encoding::BINARY, file.content.encoding
    assert_equal BYTES.bytesize, file.size
    assert_equal "Отчёт.xlsx", file.filename
    assert_equal Encoding::UTF_8, file.filename.encoding
    assert_equal XLSX, file.content_type
    assert_equal "req_file", file.request_id
    assert_equal 200, file.api_response.status
    assert_equal DISPOSITION, file.headers["content-disposition"]

    request = server.requests.last

    assert_equal "GET", request.verb
    assert_equal "/v1/companies/co_1/proposals/P-000123/export", request.path
    assert_equal "format=pdf", request.query
    assert_equal "*/*", request.headers["accept"]
    assert_equal "tg_test_key", request.headers["x-api-key"]
    assert_empty request.body
  end

  def test_inspect_shows_the_size_not_the_bytes
    server.respond { |_| file_response }
    shown = client.chat.download_file("d_1", "f_1", company_id: "co_1").inspect

    assert_includes shown, "size=#{BYTES.bytesize}"
    refute_includes shown, "not text"
  end

  def test_a_download_without_content_disposition_has_no_name
    server.respond { |_| { status: 200, headers: { "content-type" => "application/octet-stream" }, body: "\x00\x01" } }
    file = client.chat.download_file("d_1", "f_1", company_id: "co_1")

    assert_equal "\x00\x01".b, file.content
    assert_nil file.filename
    assert_equal "application/octet-stream", file.content_type
    assert_equal "/v1/companies/co_1/chat/d_1/files/f_1", server.requests.last.path
  end

  def test_a_download_error_is_the_typed_error
    server.respond do |_|
      MockServer.error(404, "not_found_error", message: "Предложение не найдено.", request_id: "req_missing")
    end
    error = assert_raises(Tungo::NotFoundError) { client(company_id: "co_1").proposals.export("P-000404") }

    assert_equal 404, error.status
    assert_equal "req_missing", error.request_id
    assert_equal "Предложение не найдено.", error.api_message
    assert_nil server.requests.last.query
    assert_equal 1, server.requests.size
  end

  def test_a_download_is_retried
    server.respond do |_, count|
      if count == 1
        MockServer.error(503, "unavailable_error", headers: { "retry-after-ms" => "1" })
      else
        file_response(BYTES, "content-type" => "text/csv", "content-disposition" => "attachment; filename=b.csv")
      end
    end
    file = client(company_id: "co_1").batches.export("b_1", format: "csv")

    assert_equal 2, server.requests.size
    assert_equal BYTES, file.content
    assert_equal "b.csv", file.filename
    assert_equal "text/csv", file.content_type
    assert_equal "format=csv", server.requests.last.query
  end
end
