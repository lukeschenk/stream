import Foundation

/// Opening episodes in the service sites, and remembering where to pick up.
extension AppModel {
    /// The streaming services in the sidebar, in sidebar order.
    var myServices: [StreamingService] {
        siteStore.sites.compactMap(Self.service(for:))
    }

    func progress(for media: TMDBMediaResult) -> EpisodeProgress? {
        watchlistStore.item(for: media)?.progress
    }

    /// Whether a sidebar site can open the episode.
    func canOpen(_ episode: TitleEpisode) -> Bool {
        episodeDestination(episode) != nil
    }

    func openEpisode(_ episode: TitleEpisode, of media: TMDBMediaResult) {
        guard let (site, url) = episodeDestination(episode) else { return }

        watchlistStore.recordEpisode(
            season: episode.season,
            episode: episode.number,
            title: episode.title,
            of: media
        )
        dismissCommandPalette()
        select(.site(site.id))
        navigate(to: url)
    }

    private func episodeDestination(_ episode: TitleEpisode) -> (SavedSite, URL)? {
        for site in siteStore.sites {
            if let service = Self.service(for: site), let url = episode.links[service.id] {
                return (site, url)
            }
        }
        return nil
    }

    private static func service(for site: SavedSite) -> StreamingService? {
        StreamingServiceCatalog.service(forProviderName: site.tmdbProvider?.name ?? site.name)
    }
}
