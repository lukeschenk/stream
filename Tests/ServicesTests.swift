import Foundation
import Testing
@testable import Wianu

@Suite("Streaming service catalog")
struct StreamingServiceCatalogTests {
    @Test(arguments: [
        ("Netflix", "Netflix"),
        ("Netflix basic with Ads", "Netflix"),
        ("Amazon Prime Video", "Prime Video"),
        ("Disney Plus", "Disney+"),
        ("Apple TV+", "Apple TV"),
        ("Crave", "Crave"),
        ("Paramount Plus Apple TV Channel", "Paramount+"),
        ("Max", "HBO Max"),
        ("Tubi TV", "Tubi"),
        ("CBC Gem", "CBC Gem")
    ])
    func `provider names map to services`(provider: String, service: String) {
        #expect(StreamingServiceCatalog.service(forProviderName: provider)?.name == service)
    }

    @Test(arguments: ["Maxdome", "Google Play Movies", "", "Hu"])
    func `unknown providers are not guessed`(provider: String) {
        #expect(StreamingServiceCatalog.service(forProviderName: provider) == nil)
    }

    @Test func `every catalog entry makes a valid site`() {
        for service in StreamingServiceCatalog.services {
            let option = ServiceOption(service: service, provider: nil, priority: 0)
            #expect(option.siteDraft().validatedValues != nil, "\(service.name)")
        }
    }

    @Test @MainActor func `options follow the region's order and keep the main provider`() {
        let providers = [
            TMDBProvider(id: 1796, name: "Netflix basic with Ads", logoPath: nil, displayPriorities: ["CA": 1]),
            TMDBProvider(id: 8, name: "Netflix", logoPath: nil, displayPriorities: ["CA": 4, "US": 1]),
            TMDBProvider(id: 230, name: "Crave", logoPath: nil, displayPriorities: ["CA": 2]),
            TMDBProvider(id: 15, name: "Hulu", logoPath: nil, displayPriorities: ["US": 2]),
            TMDBProvider(id: 3, name: "Google Play Movies", logoPath: nil, displayPriorities: ["CA": 0])
        ]

        let options = ServiceOption.options(from: providers, region: "ca")

        #expect(options.map(\.service.name) == ["Netflix", "Crave"])
        #expect(options.first?.provider?.id == 8)
        #expect(options.first?.siteDraft().tmdbProvider?.id == 8)
    }

    @Test @MainActor func `without provider data the whole catalog is offered`() {
        let options = ServiceOption.options(from: [], region: "CA")
        #expect(options.count == StreamingServiceCatalog.services.count)
    }
}

@Suite("My services")
@MainActor
struct MyServicesTests {
    private let netflix = TMDBProvider(id: 8, name: "Netflix", logoPath: nil)
    private let crave = TMDBProvider(id: 230, name: "Crave", logoPath: nil)
    private let appleStore = TMDBProvider(id: 2, name: "Apple TV", logoPath: nil)

    @Test func `only included offers count`() {
        let availability = TMDBWatchAvailability(
            link: nil,
            groups: [.flatrate: [netflix], .ads: [netflix, crave], .rent: [appleStore]]
        )
        #expect(MyServices.streamingProviders(in: availability).map(\.id) == [8, 230])
        #expect(MyServices.streamingProviders(in: nil).isEmpty)
    }

    @Test func `titles match saved sites by provider`() {
        let sites = [
            SavedSite(
                name: "Netflix",
                urlString: "https://www.netflix.com",
                tmdbProvider: .init(id: 8, name: "Netflix")
            ),
            SavedSite(name: "Blog", urlString: "https://example.com"),
            SavedSite(name: "Crave", urlString: "https://www.crave.ca", tmdbProvider: .init(id: 230, name: "Crave"))
        ]

        #expect(MyServices.sites(streaming: [crave], from: sites).map(\.name) == ["Crave"])
        #expect(MyServices.sites(streaming: [appleStore], from: sites).isEmpty)
        #expect(MyServices.hasLinkedServices(sites))
        #expect(!MyServices.hasLinkedServices([sites[1]]))
    }
}
