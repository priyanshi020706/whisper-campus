import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../home/home_feed_page.dart';
import '../../models/campus_department.dart';
import '../../models/college_details.dart';
import '../../core/utils/error_message.dart';
import '../../services/profile_setup_service.dart';

class ProfileSetupPage extends StatefulWidget {
  const ProfileSetupPage({
    super.key,
    this.isFaculty = false,
    this.loadDetails,
    this.save,
    this.onCompleted,
  });

  final bool isFaculty;

  /// Where the college details come from. Defaults to the Supabase server;
  /// tests pass their own.
  final CollegeDetailsLoader? loadDetails;

  /// How the profile is saved. Defaults to the Supabase server.
  final ProfileSaver? save;

  /// Called after a successful save. Defaults to opening the home feed.
  final VoidCallback? onCompleted;

  @override
  State<ProfileSetupPage> createState() => _ProfileSetupPageState();
}

class _ProfileSetupPageState extends State<ProfileSetupPage> {
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _bioController = TextEditingController();

  bool _loading = false;
  bool _detailsLoading = true;
  CollegeDetails? _details;
  String? _error;
  String? _departmentCode;

  @override
  void initState() {
    super.initState();
    _fetchDetails();
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _fetchDetails() async {
    CollegeDetails? details;
    try {
      final loader = widget.loadDetails ??
          () => loadCollegeDetails(Supabase.instance.client);
      details = await loader();
    } catch (error) {
      // Not fatal: without the details the screen falls back to the plain
      // optional name fields, as before.
      debugPrint('COLLEGE DETAILS ERROR: $error');
    }
    if (!mounted) return;
    setState(() {
      _details = details;
      _detailsLoading = false;
    });
  }

  Future<void> _completeProfile() async {
    if (widget.save == null && Supabase.instance.client.auth.currentUser == null) {
      setState(() => _error = 'Please sign in again.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    final locked = _details?.hasName ?? false;
    try {
      final saver = widget.save ??
          ({
            required bool isFaculty,
            required String firstName,
            required String lastName,
            String? bio,
            String? departmentCode,
          }) =>
              saveProfile(
                Supabase.instance.client,
                isFaculty: isFaculty,
                firstName: firstName,
                lastName: lastName,
                bio: bio,
                departmentCode: departmentCode,
              );
      await saver(
        isFaculty: widget.isFaculty,
        // The server uses the Google name when there is one and ignores these.
        firstName: locked ? '' : _firstNameController.text.trim(),
        lastName: locked ? '' : _lastNameController.text.trim(),
        bio: widget.isFaculty ? null : _bioController.text.trim(),
        departmentCode: _departmentCode,
      );

      if (!mounted) return;

      final done = widget.onCompleted;
      if (done != null) {
        done();
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeFeedPage()),
        );
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = friendlyError(e);
      });

      debugPrint('PROFILE SETUP ERROR: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  List<Widget> _nameSection(BuildContext context) {
    final details = _details;
    if (_detailsLoading) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    if (details != null && details.hasName) {
      return [
        LockedField(label: 'Name', value: details.fullName!),
        if (details.enrollmentNumber != null) ...[
          const SizedBox(height: 12),
          LockedField(
            label: 'Enrollment number',
            value: details.enrollmentNumber!,
          ),
        ],
        if (details.branchAndYear != null) ...[
          const SizedBox(height: 12),
          LockedField(label: 'Branch and year', value: details.branchAndYear!),
        ],
      ];
    }

    // Google gave no name (or the details could not be loaded): let the person
    // type one, as before. Enrollment is still shown when we know it.
    return [
      TextField(
        controller: _firstNameController,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
        maxLength: 60,
        decoration: const InputDecoration(
          labelText: 'First name (optional)',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _lastNameController,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
        maxLength: 60,
        decoration: const InputDecoration(
          labelText: 'Last name (optional)',
          border: OutlineInputBorder(),
        ),
      ),
      if (details?.enrollmentNumber != null) ...[
        const SizedBox(height: 12),
        LockedField(
          label: 'Enrollment number',
          value: details!.enrollmentNumber!,
        ),
      ],
    ];
  }

  String _introText() {
    final locked = _details?.hasName ?? false;
    if (locked) {
      return widget.isFaculty
          ? 'Your name comes from your MITS Google account and cannot be changed here. You can pick your department.'
          : 'Your name and enrollment number come from your MITS Google account, so they are filled in for you and cannot be changed. You can add a short bio.';
    }
    return widget.isFaculty
        ? 'Add the name people will see in Official rooms. Name and department are optional; you can continue without them.'
        : 'Add the name classmates will see in Official mode. Name is optional. Branch and year are verified from your MITS email when available; your anonymous profile stays separate.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isFaculty
              ? 'Set Up Your Faculty Profile'
              : 'Set Up Your Profile',
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.shield_outlined,
                size: 64,
                color: Colors.deepPurple,
              ),
              const SizedBox(height: 16),
              Text(
                'Welcome to Whisper Campus!',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(_introText(), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ..._nameSection(context),
              if (widget.isFaculty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: _departmentCode,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Department (optional)',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('No department selected'),
                    ),
                    ...campusDepartments.map(
                      (department) => DropdownMenuItem<String?>(
                        value: department.code,
                        child: Text(
                          '${department.name} (${department.code.toUpperCase()})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  onChanged: _loading
                      ? null
                      : (value) => setState(() => _departmentCode = value),
                ),
              ] else ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _bioController,
                  maxLength: 160,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Bio (optional)',
                    hintText: 'A little about you...',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: (_loading || _detailsLoading)
                    ? null
                    : _completeProfile,
                child: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Text('Complete Setup'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A value the person can see but not edit, such as the name from Google.
/// Long values wrap instead of overflowing.
class LockedField extends StatelessWidget {
  const LockedField({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '$label, $value, cannot be changed',
      excludeSemantics: true,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          filled: true,
          fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          suffixIcon: Icon(
            Icons.lock_outline_rounded,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
        ),
        child: Text(
          value,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    );
  }
}
