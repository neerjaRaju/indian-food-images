import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models/food.dart';

class Portion {
  const Portion({
    required this.serving,
    required this.quantity,
    required this.grams,
  });

  final ServingSize serving;
  final double quantity;
  final double grams;

  String get label => serving.isCustom
      ? '${grams.round()} g'
      : quantity == 1
          ? serving.label
          : '${_trim(quantity)} × ${serving.label}';

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
}

/// Unit chips + quantity stepper. Emits the resolved gram weight, which is the
/// only number the rest of the app needs.
class PortionSelector extends StatefulWidget {
  const PortionSelector({
    super.key,
    required this.food,
    required this.onChanged,
    this.initial,
  });

  final Food food;
  final ValueChanged<Portion> onChanged;
  final Portion? initial;

  @override
  State<PortionSelector> createState() => _PortionSelectorState();
}

class _PortionSelectorState extends State<PortionSelector> {
  late ServingSize _serving;
  late double _quantity;
  final _customController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _serving = widget.initial?.serving ?? widget.food.defaultServing;
    _quantity = widget.initial?.quantity ?? 1;
    _customController.text =
        (widget.initial?.grams ?? _serving.grams).round().toString();
    WidgetsBinding.instance.addPostFrameCallback((_) => _emit());
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  double get _grams => _serving.isCustom
      ? (double.tryParse(_customController.text) ?? 100)
      : _serving.grams * _quantity;

  void _emit() => widget.onChanged(
        Portion(serving: _serving, quantity: _quantity, grams: _grams),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final servings = widget.food.servings.isEmpty
        ? const [ServingSize.grams100]
        : widget.food.servings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in servings)
              ChoiceChip(
                label: Text(s.isCustom ? 'Custom' : s.label),
                selected: s.unit == _serving.unit,
                onSelected: (_) {
                  setState(() {
                    _serving = s;
                    _quantity = 1;
                    if (!s.isCustom) {
                      _customController.text = s.grams.round().toString();
                    }
                  });
                  _emit();
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_serving.isCustom)
          TextField(
            controller: _customController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(
              labelText: 'Weight',
              suffixText: 'g',
              prefixIcon: Icon(Icons.scale_outlined),
            ),
            onChanged: (_) {
              setState(() {});
              _emit();
            },
          )
        else
          Row(
            children: [
              IconButton.filledTonal(
                onPressed: _quantity <= 0.5
                    ? null
                    : () {
                        setState(() => _quantity =
                            (_quantity - 0.5).clamp(0.5, 20).toDouble());
                        _emit();
                      },
                icon: const Icon(Icons.remove),
              ),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      Portion._trim(_quantity),
                      style: theme.textTheme.titleLarge,
                    ),
                    Text(
                      '${_grams.round()} g total',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                onPressed: () {
                  setState(() =>
                      _quantity = (_quantity + 0.5).clamp(0.5, 20).toDouble());
                  _emit();
                },
                icon: const Icon(Icons.add),
              ),
            ],
          ),
      ],
    );
  }
}
