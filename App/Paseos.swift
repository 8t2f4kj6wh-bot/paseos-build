import SwiftUI
import CoreLocation
import MapKit

struct Punto: Codable {
    let latitud: Double
    let longitud: Double
    let fecha: Date

    var coordenada: CLLocationCoordinate2D {
        .init(latitude: latitud, longitude: longitud)
    }
}

struct Paseo: Codable, Identifiable {
    var id = UUID()
    var inicio = Date()
    var fin: Date?
    var puntos: [Punto] = []
    var metros: Double = 0

    var distancia: String {
        if metros < 1000 { return "\(Int(metros.rounded())) m" }
        return (metros / 1000).formatted(.number.precision(.fractionLength(2))) + " km"
    }
}

struct Diario: Codable {
    var activo: Paseo?
    var historial: [Paseo] = []
}

final class Grabador: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var diario = Diario()
    @Published private(set) var esperandoPermiso = false
    @Published var aviso: String?
    @Published private(set) var recuperado = false

    private let gps = CLLocationManager()
    private let archivo = URL.applicationSupportDirectory.appending(path: "paseos.json")
    private var lecturaCorrecta = true

    override init() {
        super.init()
        do {
            let datos = try Data(contentsOf: archivo)
            diario = try JSONDecoder().decode(Diario.self, from: datos)
            recuperado = diario.activo != nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Una instalación nueva comienza con el diario vacío.
        } catch {
            lecturaCorrecta = false
            aviso = "No se pudo abrir el historial. Tus datos se han conservado."
        }
        gps.activityType = .fitness
        gps.desiredAccuracy = kCLLocationAccuracyBest
        gps.distanceFilter = 5
        gps.pausesLocationUpdatesAutomatically = false
        gps.delegate = self
    }

    private func guardar(_ nuevo: Diario) -> Bool {
        do {
            try FileManager.default.createDirectory(at: archivo.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(nuevo).write(to: archivo, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            diario = nuevo
            return true
        } catch {
            aviso = "No se pudo guardar el paseo. Comprueba el espacio disponible."
            return false
        }
    }

    func iniciar() {
        guard lecturaCorrecta, diario.activo == nil else { return }
        switch gps.authorizationStatus {
        case .notDetermined:
            esperandoPermiso = true
            gps.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            var nuevo = diario
            nuevo.activo = Paseo()
            guard guardar(nuevo) else { return }
            aviso = nil
            gps.allowsBackgroundLocationUpdates = true
            gps.showsBackgroundLocationIndicator = true
            gps.startUpdatingLocation()
        default:
            aviso = "Permite el acceso a la ubicación en Ajustes > Mis Paseos."
        }
    }

    func finalizar() {
        guard var paseo = diario.activo else { return }
        paseo.fin = recuperado ? (paseo.puntos.last?.fecha ?? paseo.inicio) : Date()
        var nuevo = diario
        nuevo.activo = nil
        if !paseo.puntos.isEmpty { nuevo.historial.insert(paseo, at: 0) }
        guard guardar(nuevo) else { return }
        gps.stopUpdatingLocation()
        gps.allowsBackgroundLocationUpdates = false
        recuperado = false
        aviso = paseo.puntos.isEmpty ? "El paseo no tenía puntos GPS para guardar." : nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if esperandoPermiso, manager.authorizationStatus != .notDetermined {
            esperandoPermiso = false
            iniciar()
        } else if diario.activo != nil, !recuperado,
                  manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            aviso = "El permiso de ubicación cambió. Guarda el tramo registrado."
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard diario.activo != nil else { return }
        if (error as? CLError)?.code == .locationUnknown { return }
        aviso = "La ubicación no está disponible en este momento."
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations ubicaciones: [CLLocation]) {
        guard var paseo = diario.activo, !recuperado else { return }
        let cantidadAnterior = paseo.puntos.count
        for ubicacion in ubicaciones.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard CLLocationCoordinate2DIsValid(ubicacion.coordinate),
                  (0...50).contains(ubicacion.horizontalAccuracy),
                  ubicacion.timestamp >= paseo.inicio else { continue }
            if let ultimo = paseo.puntos.last {
                guard ubicacion.timestamp > ultimo.fecha else { continue }
                let origen = CLLocation(latitude: ultimo.latitud, longitude: ultimo.longitud)
                let metros = ubicacion.distance(from: origen)
                guard metros >= 5 else { continue }
                paseo.metros += metros
            }
            paseo.puntos.append(Punto(latitud: ubicacion.coordinate.latitude,
                                      longitud: ubicacion.coordinate.longitude,
                                      fecha: ubicacion.timestamp))
        }
        guard paseo.puntos.count != cantidadAnterior else { return }
        var nuevo = diario
        nuevo.activo = paseo
        if guardar(nuevo) { aviso = nil }
    }
}

@main
struct MisPaseosApp: App {
    @StateObject private var grabador = Grabador()

    var body: some Scene {
        WindowGroup {
            TabView {
                Actual(grabador: grabador)
                    .tabItem { Label("Paseo", systemImage: "figure.walk") }
                Historial(grabador: grabador)
                    .tabItem { Label("Historial", systemImage: "clock") }
            }
            .tint(.teal)
        }
    }
}

struct MapaRuta: View {
    let puntos: [Punto]
    let mostrarUsuario: Bool
    @State private var camara: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camara) {
            if mostrarUsuario { UserAnnotation() }
            if let primero = puntos.first {
                Marker("Inicio", systemImage: "flag", coordinate: primero.coordenada)
                    .tint(.teal)
            }
            if puntos.count > 1 {
                MapPolyline(coordinates: puntos.map(\.coordenada))
                    .stroke(.teal, lineWidth: 5)
            }
            if !mostrarUsuario, puntos.count > 1, let ultimo = puntos.last {
                Marker("Fin", systemImage: "flag.checkered", coordinate: ultimo.coordenada)
                    .tint(.indigo)
            }
        }
        .mapControls {
            if mostrarUsuario { MapUserLocationButton() }
            MapCompass()
        }
        .onChange(of: puntos.isEmpty) { _, vacio in
            if vacio { camara = .automatic }
        }
        .onChange(of: puntos.count) { _, cantidad in
            if mostrarUsuario, cantidad == 1, let primero = puntos.first {
                camara = .region(MKCoordinateRegion(center: primero.coordenada,
                                                    latitudinalMeters: 650,
                                                    longitudinalMeters: 650))
            }
        }
    }
}

struct Actual: View {
    @ObservedObject var grabador: Grabador

    var body: some View {
        NavigationStack {
            MapaRuta(puntos: grabador.diario.activo?.puntos ?? [],
                     mostrarUsuario: grabador.diario.activo != nil && !grabador.recuperado)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let paseo = grabador.diario.activo {
                            if grabador.recuperado {
                                Label("Paseo interrumpido", systemImage: "exclamationmark.circle")
                            } else if paseo.puntos.isEmpty {
                                Label("Buscando señal GPS…", systemImage: "location")
                            } else {
                                Label("Grabando paseo", systemImage: "location.fill")
                            }
                            Metricas(paseo: paseo)
                            accion(grabador.recuperado ? "Guardar tramo recuperado" : "Terminar paseo",
                                   icono: "stop.fill", ejecutar: grabador.finalizar)
                        } else {
                            Text("Registra el camino que recorres.").font(.headline)
                            accion("Empezar paseo", icono: "figure.walk", ejecutar: grabador.iniciar)
                                .disabled(grabador.esperandoPermiso)
                        }
                        if let aviso = grabador.aviso {
                            Text(aviso).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                    .background(.regularMaterial)
                }
                .navigationTitle("Mis Paseos")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func accion(_ texto: String, icono: String, ejecutar: @escaping () -> Void) -> some View {
        Button(action: ejecutar) {
            Label(texto, systemImage: icono)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
    }
}

struct Metricas: View {
    let paseo: Paseo

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { contexto in
            let segundos = max(0, Int((paseo.fin ?? contexto.date).timeIntervalSince(paseo.inicio)))
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Distancia").font(.caption).foregroundStyle(.secondary)
                    Text(paseo.distancia)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Duración").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%d:%02d:%02d", segundos / 3600, segundos / 60 % 60, segundos % 60))
                }
            }
            .font(.title2.monospacedDigit())
        }
    }
}

struct Historial: View {
    @ObservedObject var grabador: Grabador

    var body: some View {
        NavigationStack {
            Group {
                if grabador.diario.historial.isEmpty {
                    ContentUnavailableView("Aún no hay paseos guardados", systemImage: "figure.walk")
                } else {
                    List(grabador.diario.historial) { paseo in
                        NavigationLink {
                            MapaRuta(puntos: paseo.puntos, mostrarUsuario: false)
                                .safeAreaInset(edge: .bottom) {
                                    Metricas(paseo: paseo)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(20)
                                        .background(.regularMaterial)
                                }
                                .navigationTitle(paseo.inicio.formatted(date: .abbreviated, time: .shortened))
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(paseo.inicio.formatted(date: .abbreviated, time: .shortened))
                                    .font(.headline)
                                Text(paseo.distancia).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Historial")
        }
    }
}
