import Foundation

/// Links that open a streaming service, used where Wianu can't browse the
/// service itself (iPhone, iPad and Apple TV).
enum ServiceLauncher {
    /// A web link. On iPhone and iPad, iOS hands it to the service's app when
    /// it's installed. Uses the service's search for the title when Wianu
    /// knows the search format, and its home page otherwise.
    static func webURL(for service: StreamingService, title: String?) -> URL? {
        if let title,
           let template = service.searchTemplate,
           let url = StreamingSearchURL.makeURL(template: template, query: title)
        {
            return url
        }
        return URL(string: service.homepage)
    }

    /// Apple TV has no web browser, so services are opened by their app URL
    /// scheme. Only some services register one, and none take a title, so
    /// this just opens the app.
    static func appURL(for service: StreamingService) -> URL? {
        appSchemes[service.name].flatMap(URL.init(string:))
    }

    private static let appSchemes = [
        "Netflix": "nflx://",
        "YouTube": "youtube://",
        "Disney+": "disneyplus://",
        "Prime Video": "aiv://",
        "Tubi": "tubitv://"
    ]
}
