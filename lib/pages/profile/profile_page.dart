import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/profile_model.dart';
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
ProfileModel? _profile;
  bool _loading = true;
  String? _error;

  final _supabase = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _fetchProfile();
  }

  Future<void> _fetchProfile() async {
    final userId = _supabase.auth.currentUser?.id;

    if (userId == null) {
      if (!mounted) return;

      setState(() {
        _error = 'No logged-in user found.';
        _loading = false;
      });

      return;
    }

    try {
      final data = await _supabase
          .from('profiles')
          .select(
            'anon_username, avatar_seed, role, department, academic_year, bio',
          )
          .eq('id', userId)
          .single();

      if (!mounted) return;

     setState(() {
       _profile = ProfileModel.fromMap(data);
       _loading = false;
     });
     
    } on PostgrestException catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Error loading profile: ${e.message}';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Error loading profile.';
        _loading = false;
      });

      debugPrint('PROFILE ERROR: $e');
    }
  }

  Future<void> _signOut() async {
    try {
      await _supabase.auth.signOut();
    } on AuthException catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
        ),
      );
    } catch (e) {
      debugPrint('SIGN OUT ERROR: $e');
    }
  }

  Color _getAvatarColor() {
    final seed = _profile?.avatarSeed;

    if (seed == null || seed.length < 6) {
      return Colors.deepPurple;
    }

    try {
      return Color(
        int.parse('0xFF${seed.substring(0, 6)}'),
      );
    } catch (_) {
      return Colors.deepPurple;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Profile'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: _signOut,
          ),
        ],
      ),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator()
            : _error != null
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircleAvatar(
                          radius: 40,
                          backgroundColor: _getAvatarColor(),
                        ),

                        const SizedBox(height: 16),

                        Text(
                          _profile?.anonUsername ?? 'Unknown',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall,
                        ),

                        const SizedBox(height: 8),

                        Text(
                          'Role: ${_profile?.role ?? 'student'}',
                        ),

                        if (_profile?.department != null)
                          Text(
                            'Department: ${_profile!.department}',
                          ),

                        if (_profile?.academicYear!= null)
                          Text(
                            'Academic Year: ${_profile!.academicYear}',
                          ),

                        if (_profile?.bio != null &&
                            _profile!.bio
                                .toString()
                                .trim()
                                .isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              _profile!.bio!,
                              textAlign: TextAlign.center,
                            ),
                          ),
                      ],
                    ),
                  ),
      ),
    );
  }
}