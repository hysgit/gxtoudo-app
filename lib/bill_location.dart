import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

class BillLocation {
  const BillLocation(this.label, this.latitude, this.longitude);
  final String label, latitude, longitude;
}

Future<BillLocation?> locateBill() async {
  if (!await Geolocator.isLocationServiceEnabled()) return null;
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    return null;
  }
  final point = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      timeLimit: Duration(seconds: 8),
    ),
  );
  var label =
      '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}';
  try {
    final places = await placemarkFromCoordinates(
      point.latitude,
      point.longitude,
    ).timeout(const Duration(seconds: 4));
    if (places.isNotEmpty) {
      final p = places.first;
      final parts = [
        p.administrativeArea,
        p.locality,
        p.subLocality,
        p.street,
        p.name,
      ].whereType<String>().where((part) => part.trim().isNotEmpty).toSet();
      if (parts.isNotEmpty) label = parts.join(' ');
    }
  } catch (_) {
    /* Coordinates are still useful when address lookup is offline. */
  }
  return BillLocation(
    label,
    point.latitude.toString(),
    point.longitude.toString(),
  );
}
