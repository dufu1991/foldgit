import FoldGitCore
import Foundation

enum MacRepositoryDiscovery {
    static func make() -> RepositoryDiscovery {
        RepositoryDiscovery { directory in
            (try? directory.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
        }
    }
}
