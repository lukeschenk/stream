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

    enum Platform {
        /// iPhone and iPad: web links open the service's app when installed,
        /// and Safari otherwise.
        case touch
        /// Apple TV: no browser, so only links an installed app claims work.
        case appleTV
    }

    /// Links to try in order until one opens.
    static func candidates(
        for service: StreamingService,
        title: String,
        links: TitleLinks?,
        platform: Platform
    ) -> [URL] {
        let titleLink = links?.url(for: service)

        switch platform {
        case .touch:
            return [titleLink ?? webURL(for: service, title: title)].compactMap { $0 }

        case .appleTV:
            // Services that list their titles in Apple's TV app can be reached
            // through it when there's no direct link.
            let viaTVApp = servicesOutsideTVApp.contains(service.name) ? nil : links?.appleTV
            var urls = [titleLink, viaTVApp, appURL(for: service)].compactMap { $0 }
            var seen = Set<URL>()
            urls = urls.filter { seen.insert($0).inserted }
            return urls
        }
    }

    /// Apple TV has no web browser, so services are opened by their app URL
    /// scheme as a last resort. Only some services register one, and none take
    /// a title, so this just opens the app.
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

    /// Services that don't show their titles in Apple's TV app.
    private static let servicesOutsideTVApp: Set<String> = ["Netflix", "YouTube"]
}
