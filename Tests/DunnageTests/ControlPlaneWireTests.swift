import XCTest
import DunnageTransport

/// Every route this transport calls is built and read exactly as the plane speaks it.
///
/// `cloud/handlers/create.ts`, `urls.ts`, `parts.ts` and `complete.ts` are the other side
/// of these bytes: `POST /uploads {parts, ref}` answering `{uploadId}`, `POST
/// /uploads/{ref}/urls {parts, uploadId}` answering `{urls: [{partNumber, url}]}`, `GET
/// /uploads/{ref}/parts?uploadId=` answering `{parts: [n]}`, and `POST
/// /uploads/{ref}/complete {uploadId}` answering `{etag}`. The requests are asserted
/// whole, because a request fully determined by its arguments is one a test can hold
/// beside the handler. The pure half of the boundary, deterministic; no exchange is
/// touched.
final class ControlPlaneWireTests: XCTestCase {

    /// Every case runs and the ones that misbehaved are reported together; one wrong
    /// case never hides the rest.
    func testEachRouteIsBuiltAndReadExactlyAsThePlaneSpeaksIt() {
        var misbehaved: [String] = []
        func check(_ name: String, _ holds: () throws -> Bool) {
            do {
                if try !holds() { misbehaved.append(name) }
            } catch {
                misbehaved.append("\(name): threw \(error)")
            }
        }
        func answer(_ status: Int, _ json: String) -> PlaneResponse {
            PlaneResponse(status: status, body: Data(json.utf8))
        }
        func refusal<T>(_ read: () throws -> T) -> ControlPlaneError? {
            do { _ = try read() } catch let error as ControlPlaneError { return error } catch {}
            return nil
        }

        check("create is POST /uploads with a sorted body") {
            ControlPlaneWire.create(ref: "r", parts: 5)
                == PlaneRequest(method: "POST", path: "/uploads", query: [:],
                                body: Data(#"{"parts":5,"ref":"r"}"#.utf8))
        }
        check("urls is POST /uploads/{ref}/urls with a sorted body") {
            ControlPlaneWire.urls(ref: "r", uploadId: "u", parts: 5)
                == PlaneRequest(method: "POST", path: "/uploads/r/urls", query: [:],
                                body: Data(#"{"parts":5,"uploadId":"u"}"#.utf8))
        }
        check("the uploadId is read from the create answer") {
            try ControlPlaneWire.uploadId(from: answer(200, #"{"uploadId":"u"}"#)) == "u"
        }
        check("the part URLs are read beside their part numbers") {
            try ControlPlaneWire.partURLs(from: answer(200, #"{"urls":[{"partNumber":1,"url":"https://x/1"}]}"#))
                == [PartURL(part: 1, url: URL(string: "https://x/1")!)]
        }
        check("parts is GET /uploads/{ref}/parts with the uploadId in the query") {
            ControlPlaneWire.parts(ref: "r", uploadId: "u")
                == PlaneRequest(method: "GET", path: "/uploads/r/parts",
                                query: ["uploadId": "u"], body: nil)
        }
        check("complete is POST /uploads/{ref}/complete with a sorted body") {
            ControlPlaneWire.complete(ref: "r", uploadId: "u")
                == PlaneRequest(method: "POST", path: "/uploads/r/complete", query: [:],
                                body: Data(#"{"uploadId":"u"}"#.utf8))
        }
        check("the parts held are read as the set they are") {
            try ControlPlaneWire.heldParts(from: answer(200, #"{"parts":[1,3]}"#)) == [1, 3]
        }
        check("a part number below one is refused and not filtered away") {
            refusal { try ControlPlaneWire.heldParts(from: answer(200, #"{"parts":[0,1]}"#)) }
                == .unreadableAnswer(status: 200)
        }
        check("a part number that is not an integer is refused") {
            refusal { try ControlPlaneWire.heldParts(from: answer(200, #"{"parts":["1"]}"#)) }
                == .unreadableAnswer(status: 200)
        }
        check("a complete the plane answered is read as done, and its etag is not read") {
            try { try ControlPlaneWire.completed(from: answer(200, #"{"etag":"x"}"#)); return true }()
        }
        check("the stand-in's refusal of a complete over parts it does not hold is named") {
            refusal { try ControlPlaneWire.completed(from: answer(400, #"{"error":"incomplete upload"}"#)) }
                == .incompleteUpload
        }
        check("any other 400 from the complete route is the route's own refusal") {
            refusal { try ControlPlaneWire.completed(from: answer(400, #"{"error":"missing uploadId"}"#)) }
                == .refused(status: 400)
        }

        let statuses: [(Int, ControlPlaneError)] = [
            (400, .refused(status: 400)),
            (401, .refused(status: 401)),
            (403, .refused(status: 403)),
            (404, .noSuchUpload),
            (500, .unexpectedStatus(500)),
            (200, .unreadableAnswer(status: 200)),
        ]
        for (status, expected) in statuses {
            let body = status == 200 ? "{}" : #"{"error":"x"}"#
            check("\(status) reading an uploadId is \(expected)") {
                refusal { try ControlPlaneWire.uploadId(from: answer(status, body)) } == expected
            }
            check("\(status) reading part URLs is \(expected)") {
                refusal { try ControlPlaneWire.partURLs(from: answer(status, body)) } == expected
            }
            check("\(status) reading the parts held is \(expected)") {
                refusal { try ControlPlaneWire.heldParts(from: answer(status, body)) } == expected
            }
        }

        XCTAssertEqual(misbehaved, [], "the wire does not speak the routes as the plane does")
    }
}
