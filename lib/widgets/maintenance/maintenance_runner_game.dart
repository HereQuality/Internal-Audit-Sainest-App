import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A tiny offline-style runner (Chrome's dino game, reskinned) shown on
/// MaintenanceBlockScreen to keep people occupied while blocked — same
/// idea as the web app's Components/Common/DinoRunnerGame.jsx, just a
/// native CustomPainter/Ticker implementation instead of <canvas>. No new
/// package dependency. Tap to jump, high score persisted locally.

const double _gravity = 2600;
const double _jumpVelocity = -900;
const double _baseSpeed = 240;
const double _speedRamp = 3.2;
const double _playerSize = 28;
const double _playerX = 28;
const double _gameHeight = 170;
const double _groundY = _gameHeight * 0.78;
const double _floorY = _groundY - _playerSize;
const _highScoreKey = 'maintenance_runner_highscore';

class MaintenanceRunnerGame extends StatefulWidget {
  const MaintenanceRunnerGame({super.key});

  @override
  State<MaintenanceRunnerGame> createState() => _MaintenanceRunnerGameState();
}

enum _RunState { idle, playing, over }

class _Obstacle {
  double x;
  final double w;
  final double h;
  _Obstacle(this.x, this.w, this.h);
}

class _MaintenanceRunnerGameState extends State<MaintenanceRunnerGame> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  double _width = 320;

  _RunState _state = _RunState.idle;
  double _playerY = _floorY;
  double _playerVy = 0;
  bool _jumping = false;
  double _elapsed = 0;
  double _spawnTimer = 0.9;
  double _score = 0;
  int _highScore = 0;
  final List<_Obstacle> _obstacles = [];
  final _rand = Random();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _loadHighScore();
  }

  Future<void> _loadHighScore() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _highScore = prefs.getInt(_highScoreKey) ?? 0);
  }

  void _resetWorld() {
    _playerY = _floorY;
    _playerVy = 0;
    _jumping = false;
    _elapsed = 0;
    _spawnTimer = 0.9;
    _score = 0;
    _obstacles.clear();
  }

  void _jump() {
    if (_state != _RunState.playing) {
      _resetWorld();
      setState(() => _state = _RunState.playing);
      return;
    }
    if (!_jumping) {
      _playerVy = _jumpVelocity;
      _jumping = true;
    }
  }

  void _onTick(Duration elapsed) {
    if (_lastTick == Duration.zero) {
      _lastTick = elapsed;
      return;
    }
    final dt = ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.033);
    _lastTick = elapsed;

    if (_state != _RunState.playing) return;

    _elapsed += dt;
    final speed = _baseSpeed + _elapsed * _speedRamp;
    _score += dt * 12;

    _playerVy += _gravity * dt;
    _playerY += _playerVy * dt;
    if (_playerY >= _floorY) {
      _playerY = _floorY;
      _playerVy = 0;
      _jumping = false;
    }

    _spawnTimer -= dt;
    if (_spawnTimer <= 0) {
      final tall = _rand.nextDouble() > 0.6;
      _obstacles.add(_Obstacle(_width + 10, tall ? 14 : 20, tall ? 32 : 18));
      _spawnTimer = max(0.5, 1.2 - _elapsed * 0.015) + _rand.nextDouble() * 0.45;
    }
    for (final o in _obstacles) {
      o.x -= speed * dt;
    }
    _obstacles.removeWhere((o) => o.x + o.w < -10);

    const inset = 5.0;
    for (final o in _obstacles) {
      final oy = _groundY - o.h;
      final overlap = _playerX + inset < o.x + o.w &&
          _playerX + _playerSize - inset > o.x &&
          _playerY + inset < oy + o.h &&
          _playerY + _playerSize - inset > oy;
      if (overlap) {
        final finalScore = _score.floor();
        if (finalScore > _highScore) {
          _highScore = finalScore;
          SharedPreferences.getInstance().then((p) => p.setInt(_highScoreKey, finalScore));
        }
        setState(() => _state = _RunState.over);
        return;
      }
    }

    setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: _jump,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: _gameHeight,
          width: double.infinity,
          color: scheme.surfaceContainerLow,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _width = constraints.maxWidth;
              return Stack(
                children: [
                  CustomPaint(
                    size: Size(constraints.maxWidth, _gameHeight),
                    painter: _RunnerPainter(
                      playerY: _playerY,
                      obstacles: _obstacles,
                      score: _score.floor(),
                      highScore: _highScore,
                      primary: scheme.primary,
                      textColor: scheme.onSurface,
                    ),
                  ),
                  if (_state != _RunState.playing)
                    Positioned.fill(
                      child: Container(
                        alignment: Alignment.center,
                        color: scheme.surface.withValues(alpha: 0.35),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _state == _RunState.idle ? 'Tap to play' : 'Game over — score ${_score.floor()}',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _state == _RunState.over ? 'Tap to try again' : 'Jump the flags while you wait',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RunnerPainter extends CustomPainter {
  final double playerY;
  final List<_Obstacle> obstacles;
  final int score;
  final int highScore;
  final Color primary;
  final Color textColor;

  _RunnerPainter({
    required this.playerY,
    required this.obstacles,
    required this.score,
    required this.highScore,
    required this.primary,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final groundPaint = Paint()
      ..color = textColor.withValues(alpha: 0.25)
      ..strokeWidth = 2;
    canvas.drawLine(const Offset(0, _groundY), Offset(size.width, _groundY), groundPaint);

    final playerRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(_playerX, 0, _playerSize, _playerSize).shift(Offset(0, playerY)),
      const Radius.circular(7),
    );
    canvas.drawRRect(playerRect, Paint()..color = primary);

    final obstaclePaint = Paint()..color = const Color(0xFFDC2626);
    for (final o in obstacles) {
      final oy = _groundY - o.h;
      canvas.drawRect(Rect.fromLTWH(o.x, oy, o.w, o.h), obstaclePaint);
    }

    final tp = TextPainter(
      text: TextSpan(
        text: '${score.toString().padLeft(5, '0')}\nHI ${highScore.toString().padLeft(5, '0')}',
        style: TextStyle(color: textColor.withValues(alpha: 0.8), fontSize: 12, fontWeight: FontWeight.w600, height: 1.5),
      ),
      textAlign: TextAlign.right,
      textDirection: TextDirection.ltr,
    )..layout(minWidth: 0, maxWidth: size.width - 16);
    tp.paint(canvas, Offset(size.width - tp.width - 12, 10));
  }

  @override
  bool shouldRepaint(covariant _RunnerPainter oldDelegate) => true;
}
