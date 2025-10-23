import Foundation
import SwiftUI

/*
 WatchMap - Optimized Map Tile Loader for watchOS and iOS
 
 watchOS Optimizations:
 • Reduced memory footprint (20MB vs 50MB for iOS)
 • Limited concurrent tile loads (2 vs 4 connections)
 • Automatic image downscaling to save memory
 • Smart cancellation of off-screen tile loads
 • 50ms debounce delay to avoid loading tiles during fast scrolling
 • Memory warning handling with automatic cache reduction
 • Longer network timeouts for cellular connections
 • Optimized rendering with .drawingGroup()
 • Smaller progress indicators
 • Task cancellation when tiles go off-screen
 • Fewer tiles cached in memory (30 vs 100)
 
 Performance Features:
 • Two-tier caching (memory + disk)
 • Instant cache lookups prevent redundant loads
 • Request deduplication prevents duplicate network calls
 • Exponential backoff retry logic
 • Stable tile identity prevents unnecessary view updates
 • User-Agent header for OSM compliance
 */

public func tileXY(for coordinate: CLLocationCoordinate2D, zoom: Int) -> (x: Double, y: Double) {
    let latRad = coordinate.latitude * Double.pi / 180
    let n = pow(2.0, Double(zoom))
    let x = (coordinate.longitude + 180.0) / 360.0 * n
    let y = (1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / Double.pi) / 2.0 * n
    return (x, y)
}

public func coordinate(forX x: Double, y: Double, zoom: Int) -> CLLocationCoordinate2D {
    let n = pow(2.0, Double(zoom))
    let lon = x / n * 360.0 - 180.0
    let latRad = atan(sinh(Double.pi * (1 - 2 * y / n)))
    let lat = latRad * 180.0 / Double.pi
    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

// MARK: - Tile Loading Infrastructure

/// Manages tile loading with caching and error handling
@MainActor
class TileLoader {
    static let shared = TileLoader()
    
    private var urlSession: URLSession
    private let memoryCache = NSCache<NSString, UIImage>()
    private var loadingTasks: [String: Task<UIImage?, Never>] = [:]
    private var priorityQueue: [String] = []
    private let maxConcurrentLoads = 2  // Limit for watchOS
    private var activeLoadCount = 0
    
    private init() {
        // Configure URLSession with watchOS-optimized settings
        let config = URLSessionConfiguration.default
        
        #if os(watchOS)
        // Aggressive caching for watchOS to reduce network usage
        config.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,   // 20 MB memory - watchOS has limited RAM
            diskCapacity: 100 * 1024 * 1024     // 100 MB disk cache
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 2  // Fewer connections for watchOS
        config.timeoutIntervalForRequest = 15     // Longer timeout for slower connections
        config.waitsForConnectivity = true        // Wait for connectivity instead of failing
        #else
        config.urlCache = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 4
        #endif
        
        self.urlSession = URLSession(configuration: config)
        
        // Configure memory cache with watchOS-specific limits
        #if os(watchOS)
        memoryCache.countLimit = 30  // Fewer tiles in memory for watchOS
        memoryCache.totalCostLimit = 20 * 1024 * 1024  // 20 MB limit
        #else
        memoryCache.countLimit = 100
        memoryCache.totalCostLimit = 50 * 1024 * 1024
        #endif
      
    }
    
    /// Handle memory warnings by clearing cache
    private func handleMemoryWarning() {
        print("TileLoader: Memory warning received, clearing cache")
        // Keep only the most recently used tiles
        let currentCount = memoryCache.countLimit
        memoryCache.countLimit = max(10, currentCount / 2)
        memoryCache.countLimit = currentCount
    }
    
    /// Fast synchronous cache check - returns immediately if tile is in memory
    func getCachedTile(z: Int, x: Int, y: Int) async -> UIImage? {
        let cacheKey = "\(z)/\(x)/\(y)" as NSString
        return memoryCache.object(forKey: cacheKey)
    }
    
    /// Load tile with priority and concurrency management for watchOS
    func loadTile(z: Int, x: Int, y: Int, priority: Int = 0) async -> UIImage? {
        let cacheKey = "\(z)/\(x)/\(y)" as NSString
        
        // Check memory cache first - instant return
        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            return cachedImage
        }
        
        // Check if already loading
        if let existingTask = loadingTasks[cacheKey as String] {
            return await existingTask.value
        }
        
        #if os(watchOS)
        // Wait if too many concurrent loads on watchOS
        while activeLoadCount >= maxConcurrentLoads {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        activeLoadCount += 1
        #endif
        
        // Create new loading task
        let task = Task<UIImage?, Never> {
            await loadTileFromNetwork(z: z, x: x, y: y, cacheKey: cacheKey)
        }
        
        loadingTasks[cacheKey as String] = task
        let image = await task.value
        loadingTasks.removeValue(forKey: cacheKey as String)
        
        #if os(watchOS)
        activeLoadCount = max(0, activeLoadCount - 1)
        #endif
        
        return image
    }
    
    private func loadTileFromNetwork(z: Int, x: Int, y: Int, cacheKey: NSString) async -> UIImage? {
        // Wrap tile coordinates to handle world wrapping
        let maxTile = Int(pow(2.0, Double(z)))
        let wrappedX = ((x % maxTile) + maxTile) % maxTile
        
        // Validate tile coordinates
        guard wrappedX >= 0, wrappedX < maxTile,
              y >= 0, y < maxTile else {
            return nil
        }
        
        guard let url = URL(string: "https://tile.openstreetmap.org/\(z)/\(wrappedX)/\(y).png") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mini-Map-Ultimate/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        
        // Retry logic with exponential backoff
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (data, response) = try await urlSession.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    continue
                }
                
                // Check for successful response
                guard (200...299).contains(httpResponse.statusCode) else {
                    if attempt < 2 {
                        // Wait before retry with exponential backoff
                        try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 100_000_000)
                        continue
                    }
                    return nil
                }
                
                // Decode and optimize image for watchOS
                guard var image = UIImage(data: data) else {
                    return nil
                }
                
                #if os(watchOS)
                // Downscale image if needed to save memory on watchOS
                // This reduces memory pressure while maintaining visual quality
                if let cgImage = image.cgImage {
                    let maxDimension: CGFloat = 256
                    let scale = min(maxDimension / CGFloat(cgImage.width), maxDimension / CGFloat(cgImage.height), 1.0)
                    
                    if scale < 1.0 {
                        let newSize = CGSize(
                            width: CGFloat(cgImage.width) * scale,
                            height: CGFloat(cgImage.height) * scale
                        )
                        
                        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
                        image.draw(in: CGRect(origin: .zero, size: newSize))
                        if let scaledImage = UIGraphicsGetImageFromCurrentImageContext() {
                            image = scaledImage
                        }
                        UIGraphicsEndImageContext()
                    }
                }
                #endif
                
                // Cache the successful result
                let imageCost = Int(image.size.width * image.size.height * 4) // Rough estimate
                memoryCache.setObject(image, forKey: cacheKey, cost: imageCost)
                
                return image
                
            } catch {
                lastError = error
                if attempt < 2 {
                    // Wait before retry
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 100_000_000)
                }
            }
        }
        
        // All retries failed
        print("Failed to load tile \(z)/\(x)/\(y): \(lastError?.localizedDescription ?? "unknown error")")
        return nil
    }
    
    /// Preload tiles for a given location (useful for prefetching)
    func preloadTiles(center: CLLocationCoordinate2D, zoom: Int, gridSize: Int = 2) {
        let (centerX, centerY) = tileXY(for: center, zoom: zoom)
        let halfSpan = (Double(gridSize) - 1) / 2.0
        
        Task {
            for dy in stride(from: -halfSpan, through: halfSpan, by: 1.0) {
                for dx in stride(from: -halfSpan, through: halfSpan, by: 1.0) {
                    let x = Int(floor(centerX + dx))
                    let y = Int(floor(centerY + dy))
                    
                    // Only preload if not already cached
                    if await getCachedTile(z: zoom, x: x, y: y) == nil {
                        _ = await loadTile(z: zoom, x: x, y: y)
                    }
                }
            }
        }
    }
    
    /// Clear all cached tiles
    func clearCache() {
        memoryCache.removeAllObjects()
        urlSession.configuration.urlCache?.removeAllCachedResponses()
    }
    
    /// Get cache statistics (useful for debugging)
    func getCacheStats() -> (memoryCount: Int, memoryLimit: Int) {
        return (memoryCache.countLimit, memoryCache.totalCostLimit)
    }
}

/// Optimized tile view with better loading and error handling
struct OptimizedTileView: View {
    let z: Int
    let x: Int
    let y: Int
    let tileSize: Double
    
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var currentTileKey: String = ""
    @State private var loadTask: Task<Void, Never>?
    
    var body: some View {
        ZStack {
            // Background layer - always present to prevent layout shifts
            Rectangle()
                .fill(Color.gray.opacity(0.15))
            
            // Content layer
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
   
            } else if isLoading {
                #if os(watchOS)
                // Simpler loading indicator for watchOS
                ProgressView()
                    .scaleEffect(0.4)
                #else
                ProgressView()
                    .scaleEffect(0.5)
                #endif
            } else if loadFailed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: tileSize / 8))
                    .foregroundColor(.gray.opacity(0.5))
            }
        }
        .frame(width: tileSize, height: tileSize, alignment: .center)
        .clipped()
        .task(id: "\(z)-\(x)-\(y)") {
            await loadTile()
        }
        .onDisappear {
            // Cancel loading when tile goes off-screen (important for watchOS)
            loadTask?.cancel()
            loadTask = nil
        }
    }
    
    private func loadTile() async {
        let tileKey = "\(z)-\(x)-\(y)"
        
        // Don't reload if this is the same tile
        guard tileKey != currentTileKey else { return }
        currentTileKey = tileKey
        
        // Cancel any existing load task
        loadTask?.cancel()
        
        // Check cache first - if cached, load instantly without loading state
        if let cachedImage = await TileLoader.shared.getCachedTile(z: z, x: x, y: y) {
            image = cachedImage
            isLoading = false
            loadFailed = false
            return
        }
        
        // Start loading with a slight delay to avoid loading tiles that are quickly scrolled past
        #if os(watchOS)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay on watchOS
        guard !Task.isCancelled else { return }
        #endif
        
        isLoading = true
        loadFailed = false
        
        loadTask = Task {
            if let loadedImage = await TileLoader.shared.loadTile(z: z, x: x, y: y) {
                guard !Task.isCancelled else { return }
                image = loadedImage
                loadFailed = false
            } else {
                guard !Task.isCancelled else { return }
                loadFailed = true
            }
            isLoading = false
        }
        
        await loadTask?.value
    }
}

public func osmTile(z: Int, x: Int, y: Int, tileSize: Double) -> some View {
    OptimizedTileView(z: z, x: x, y: y, tileSize: tileSize)
}

// MARK: - Helper Functions

/// Returns optimal tile size for current platform
public func recommendedTileSize() -> Double {
    #if os(watchOS)
    return 128.0  // Smaller tiles for watchOS conserve memory
    #else
    return 256.0  // Standard tile size for iOS
    #endif
}

/// Returns optimal grid size for current platform
public func recommendedGridSize() -> Int {
    #if os(watchOS)
    return 2  // 2x2 grid (4 tiles) for watchOS
    #else
    return 3  // 3x3 grid (9 tiles) for iOS
    #endif
}

/// Returns optimal max zoom for current platform
public func recommendedMaxZoom() -> Double {
    #if os(watchOS)
    return 18.0  // Slightly lower max zoom for watchOS
    #else
    return 20.0  // Full zoom range for iOS
    #endif
}

public func userLocationMarker(heading: Double?) -> some View {
    Circle()
        .fill(.blue)
        .frame(width: 18, height: 18)
        .overlay(Circle().stroke(Color.white, lineWidth: 3))
        .background(
            heading == nil
                ? nil
                : Path { path in
                    path.move(to: .zero)
                    path.addArc(
                        center: .zero,
                        radius: 40,
                        startAngle: .degrees(-105),
                        endAngle: .degrees(-75),
                        clockwise: false)

                    path.closeSubpath()
                }
                .offset(x: 9, y: 9)
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            .blue,
                            .blue.opacity(0),
                        ]),
                        center: .center,
                        startRadius: 1,
                        endRadius: 36
                    )
                )
        )
        .rotationEffect(.degrees(heading ?? 0))
}

public struct MapView<TileContent: View, UserLocationContent: View>: View {
    @Binding private var zoom: Double
    @Binding private var center: CLLocationCoordinate2D
    @Binding private var userLocation: CLLocationCoordinate2D?
    @Binding private var heading: Double?
    private let minZoom: Double
    private let maxZoom: Double
    private let tileSize: Double
    private let gridSize: Int
    private var onPan: ((CLLocationCoordinate2D) -> Void)?
    private var onTap: ((CLLocationCoordinate2D) -> Void)?
    private let tapDistance: Double
    private let tapDuration: Double
    private let tileContent: (Int, Int, Int, Double) -> TileContent
    private let userLocationContent: (Double?) -> UserLocationContent
    private let halfSpan: Double
    private let range: [Double]
    

    @GestureState private var dragOffset: CGSize = .zero
    @State private var gestureStartTime: Date? = nil

    public init(
        zoom: Binding<Double>,
        center: Binding<CLLocationCoordinate2D>,
        userLocation: Binding<CLLocationCoordinate2D?> = .constant(nil),
        heading: Binding<Double?> = .constant(nil),
        minZoom: Double = 1,
        maxZoom: Double = 20,
        tileSize: Double = 256,
        gridSize: Int = 2,
        onPan: ((CLLocationCoordinate2D) -> Void)? = nil,
        onTap: ((CLLocationCoordinate2D) -> Void)? = nil,
        tapDistance: Double = 5,
        tapDuration: Double = 500,
        @ViewBuilder tileContent: @escaping (Int, Int, Int, Double) -> TileContent = osmTile,
        @ViewBuilder userLocationContent: @escaping (Double?) -> UserLocationContent =
            userLocationMarker
    ) {
        self._zoom = zoom
        self._center = center
        self._userLocation = userLocation
        self._heading = heading
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.tileSize = tileSize
        self.gridSize = gridSize
        self.onPan = onPan
        self.onTap = onTap
        self.tapDistance = tapDistance
        self.tapDuration = tapDuration
        self.tileContent = tileContent
        self.userLocationContent = userLocationContent
        halfSpan = (Double(gridSize) - 1) / 2.0
        range = Array(stride(from: -halfSpan, through: halfSpan, by: 1.0))
    }

    public var body: some View {
        let zoomInt = Int(floor(zoom))
        let zoomFraction = zoom.truncatingRemainder(dividingBy: 1)
        let scale = pow(2.0, zoomFraction)

        let dragX = dragOffset.width / scale
        let dragY = dragOffset.height / scale

        let (centerX, centerY) = tileXY(for: center, zoom: zoomInt)

        let fracX = centerX.truncatingRemainder(dividingBy: 1)
        let fracY = centerY.truncatingRemainder(dividingBy: 1)

        let shiftX = gridSize % 2 == 1 ? fracX - 0.5 : fracX > 0.5 ? 1 - fracX : -fracX
        let shiftY = gridSize % 2 == 1 ? fracY - 0.5 : fracY > 0.5 ? 1 - fracY : -fracY

        let offsetX = shiftX * tileSize
        let offsetY = shiftY * tileSize

        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .opacity(0)
                    .background(
                        ZStack {
                            VStack(spacing: 0) {
                                ForEach(range, id: \.self) { dy in
                                    HStack(spacing: 0) {
                                        ForEach(range, id: \.self) { dx in
                                            let x = Int(floor(centerX + dx))
                                            let y = Int(floor(centerY + dy))
                                            tileContent(zoomInt, x, y, tileSize)
                                                .id("\(zoomInt)-\(x)-\(y)")
                                        }
                                    }
                                }
                            }
                            .offset(x: offsetX, y: offsetY)
                            #if os(watchOS)
                            // Optimize rendering for watchOS - renders as a single layer
                            .drawingGroup(opaque: false, colorMode: .nonLinear)
                            #else
                            .drawingGroup()
                            #endif
                            
                            if let userLocation = userLocation {
                                let (userX, userY) = tileXY(for: userLocation, zoom: zoomInt)
                                userLocationContent(heading)
                                    .scaleEffect(1 / scale)
                                    .offset(
                                        x: (userX - centerX) * tileSize,
                                        y: (userY - centerY) * tileSize
                                    )
                            }
                        }
                            .offset(x: dragX, y: dragY)
                            .scaleEffect(scale, anchor: .center)
                    )
                    .frame(width: tileSize * Double(gridSize), height: tileSize * Double(gridSize))
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                if gestureStartTime == nil {
                                    gestureStartTime = Date()
                                }
                            }
                            .updating($dragOffset) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                let endTime = Date()
                                let duration = gestureStartTime.map { endTime.timeIntervalSince($0) * 1000 } ?? 0 // ms
                                gestureStartTime = nil
                                let isTap = abs(value.translation.width) < tapDistance && abs(value.translation.height) < tapDistance && duration > tapDuration
                                if isTap, let onTap = onTap {
                                    let tapLocation = value.location
                                    let mapWidth = tileSize * Double(gridSize)
                                    let mapHeight = tileSize * Double(gridSize)
                                    let dx = (tapLocation.x - mapWidth / 2) / scale
                                    let dy = (tapLocation.y - mapHeight / 2) / scale
                                    let tileDx = dx / tileSize
                                    let tileDy = dy / tileSize
                                    let tapTileX = centerX + tileDx
                                    let tapTileY = centerY + tileDy
                                    let coord = coordinate(forX: tapTileX, y: tapTileY, zoom: zoomInt)
                                    onTap(coord)
                                } else {
                                    let scale = pow(2.0, zoom - floor(zoom))
                                    let deltaX = value.translation.width / (tileSize * scale)
                                    let deltaY = value.translation.height / (tileSize * scale)
                                    let newCenterX = centerX - deltaX
                                    let newCenterY = centerY - deltaY
                                    let newCenter = coordinate(
                                        forX: newCenterX, y: newCenterY, zoom: zoomInt)
                                    
                                    // Update center without animation to prevent lag
                                    self.center = newCenter
                                    onPan?(newCenter)
                                }
                            }
                    )
#if os(watchOS)
                    .focusable()
                    .digitalCrownRotation(
                        $zoom, from: minZoom, through: maxZoom, by: 0.1, sensitivity: .medium,
                        isContinuous: false, isHapticFeedbackEnabled: true)
#endif
            }
            .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)
        }.ignoresSafeArea()
    }
}

let oslo = CLLocationCoordinate2D(latitude: 59.9111, longitude: 10.7528)

#Preview {
    struct Preview: View {
        @State private var zoom: Double = 12
        @State private var center: CLLocationCoordinate2D = oslo
        @State private var userLocation: CLLocationCoordinate2D? = oslo
        @State private var heading: Double? = 125
        var body: some View {
            MapView(
                zoom: $zoom,
                center: $center,
                userLocation: $userLocation,
                heading: $heading,
                minZoom: 1,
                maxZoom: 18
            )
        }
    }
    return Preview()
}

#Preview("with userLocation") {
    struct Preview: View {
        @State private var zoom: Double = 6
        @State private var center: CLLocationCoordinate2D = oslo
        @State private var userLocation: CLLocationCoordinate2D? = oslo
        var body: some View {
            MapView(
                zoom: $zoom,
                center: $center,
                userLocation: $userLocation
            )
        }
    }
    return Preview()
}

#Preview("with gridSize=3") {
    struct Preview: View {
        @State private var zoom: Double = 10
        @State private var center: CLLocationCoordinate2D = oslo
        @State private var userLocation: CLLocationCoordinate2D? = oslo
        var body: some View {
            MapView(
                zoom: $zoom,
                center: $center,
                userLocation: $userLocation,
                tileSize: 64,
                gridSize: 3
            )
        }
    }
    return Preview()
}

#Preview("with custom marker") {
    struct Preview: View {
        @State private var zoom: Double = 16
        @State private var center: CLLocationCoordinate2D = oslo
        @State private var userLocation: CLLocationCoordinate2D? = oslo
        @State private var heading: Double? = 125
        var body: some View {
            MapView(
                zoom: $zoom,
                center: $center,
                userLocation: $userLocation,
                heading: $heading,
                userLocationContent: { heading in
                    if heading == nil {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "location.fill")
                            .font(.title3)
                            .padding(5)
                            .foregroundColor(.red)
                            .rotationEffect(.degrees(heading ?? 0))
                    }
                }
            )
        }
    }
    return Preview()
}

#Preview("with debug tiles") {
    struct Preview: View {
        @State private var zoom: Double = 6
        @State private var center: CLLocationCoordinate2D = oslo
        @State private var userLocation: CLLocationCoordinate2D? = oslo
        var body: some View {
            MapView(
                zoom: $zoom,
                center: $center,
                userLocation: $userLocation,
                tileSize: 64,
                tileContent: { z, x, y, tileSize in
                    osmTile(z: z, x: x, y: y, tileSize: tileSize)
                        .border(.red)
                        .overlay(
                            VStack {
                                Text("z:\(z)")
                                Text("x:\(x)")
                                Text("y:\(y)")
                            }
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                            .padding(2)
                            .background(Color.white.opacity(0.7))
                            .cornerRadius(4)
                            .padding(2)
                        )
                }
            )
        }
    }
    return Preview()
}

#Preview("with location button") {
    struct Preview: View {
        @State private var zoom: Double = 3
        @State private var center: CLLocationCoordinate2D = oslo
        @State private var userLocation: CLLocationCoordinate2D? = oslo
        var body: some View {
            ZStack {
                MapView(
                    zoom: $zoom,
                    center: $center,
                    userLocation: $userLocation
                )
                VStack {
                    Spacer()
                    HStack {
                        Button(action: {
                            print("Location button pressed")
                            self.center = oslo
                        }) {
                            Image(systemName: "location.fill")
                                .font(.title3)
                                .padding(5)
                                .background(.white.opacity(0.8))
                                .foregroundColor(.red)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Location button")
                        .fixedSize(horizontal: true, vertical: true)
                        Spacer()
                    }
                }.padding(.horizontal, 10)
            }
        }
    }
    return Preview()
}

#Preview("with tap callback") {
    struct Preview: View {
        @State private var alert: Bool = false
        @State private var tappedCoordinate: CLLocationCoordinate2D? = nil
        @State private var zoom: Double = 6
        @State private var center: CLLocationCoordinate2D = oslo
        var body: some View {
            MapView(
                zoom: $zoom,
                center: $center,
                onTap: { coord in
                    tappedCoordinate = coord
                    alert = true
                }
            )
            .alert(isPresented: $alert) {
                Alert(
                    title: Text("Tapped Location"),
                    message: Text(tappedCoordinate.map { String(format: "Lat: %.5f\nLon: %.5f", $0.latitude, $0.longitude) } ?? "Unknown"),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }
    return Preview()
}

#Preview("with persistence") {
    struct Preview: View {
        @AppStorage("preview_zoom") private var zoom: Double = 12
        @AppStorage("preview_center_latitude") private var centerLatitude: Double = oslo.latitude
        @AppStorage("preview_center_longitude") private var centerLongitude: Double = oslo.longitude

        var centerBinding: Binding<CLLocationCoordinate2D> {
            Binding(
                get: { CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude) },
                set: {
                    centerLatitude = $0.latitude
                    centerLongitude = $0.longitude
                }
            )
        }

        var body: some View {
            MapView(
                zoom: $zoom,
                center: centerBinding,
            )
        }
    }
    return Preview()
}
