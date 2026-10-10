class Credentials {
  final String vid;
  final String accessToken;
  final String refreshToken;
  final String deviceId;

  const Credentials({
    required this.vid,
    required this.accessToken,
    required this.refreshToken,
    required this.deviceId,
  });

  factory Credentials.fromJson(Map<String, dynamic> json) {
    final credentials = Credentials(
      vid: json['vid']?.toString() ?? '',
      accessToken: json['accessToken'] as String? ?? '',
      refreshToken: json['refreshToken'] as String? ?? '',
      deviceId: json['deviceId'] as String? ?? '',
    );
    if (!credentials.isValid) throw const FormatException('移动端凭据格式无效');
    return credentials;
  }

  bool get isValid => RegExp(r'^[0-9]+$').hasMatch(vid) && vid != '0' &&
      [accessToken, refreshToken, deviceId].every((value) =>
          value.isNotEmpty && !RegExp(r'[;\s\x00-\x1f\x7f]').hasMatch(value));

  Map<String, dynamic> toJson() => {
    'vid': vid,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'deviceId': deviceId,
  };
}

const mobileVersionHeaders = {
  'baseapi': '30',
  'appver': '2.1.2.10245900',
  'basever': '2.1.2.10245900',
  'osver': '11',
  'channelId': '900',
  'User-Agent': 'WeRead/2.1.2 WRBrand/Onyx wr_eink Dalvik/2.1.0 '
      '(Linux; U; Android 11; BOOX Build/onyx)',
};
