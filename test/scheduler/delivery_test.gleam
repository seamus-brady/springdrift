import gleeunit/should
import profile/types.{FileDelivery, WebhookDelivery}
import scheduler/delivery
import simplifile

pub fn deliver_to_file_markdown_test() {
  let dir = "/tmp/springdrift_test_delivery"
  let _ = simplifile.delete(dir)
  let config = FileDelivery(directory: dir, format: "markdown")
  let result =
    delivery.deliver("# Test Report\n\nContent here.", "test-job", config)
  result |> should.be_ok
  // Verify file exists
  let assert Ok(path) = result
  let assert Ok(content) = simplifile.read(path)
  content |> should.equal("# Test Report\n\nContent here.")
  let _ = simplifile.delete(dir)
  Nil
}

pub fn deliver_to_file_json_test() {
  let dir = "/tmp/springdrift_test_delivery_json"
  let _ = simplifile.delete(dir)
  let config = FileDelivery(directory: dir, format: "json")
  let result = delivery.deliver("{\"data\": 1}", "json-job", config)
  result |> should.be_ok
  let assert Ok(path) = result
  should.be_true(path != "")
  let _ = simplifile.delete(dir)
  Nil
}

pub fn deliver_webhook_invalid_url_returns_error_test() {
  let config = WebhookDelivery(url: "not-a-url", method: "POST", headers: [])
  let result = delivery.deliver("{\"data\": 1}", "test-job", config)
  result |> should.be_error
}
