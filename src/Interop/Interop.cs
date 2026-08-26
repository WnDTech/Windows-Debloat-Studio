// Windows Debloat Studio - review, apply and reverse what Windows 11 ships with.
// Copyright (C) 2026 WndTech
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along with
// this program. If not, see <https://www.gnu.org/licenses/>.

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;

namespace Debloat
{
    // Windows works out which taskbar button a window belongs to from the
    // process's Application User Model ID, and when none is set it falls back to
    // the executable path. This app's window is created by powershell.exe, so
    // without an explicit id the taskbar shows PowerShell's icon and groups the
    // window with any other PowerShell window - no matter what icon the exe the
    // user double-clicked carries, and no matter what Window.Icon is set to.
    // Window.Icon fixes Alt-Tab and the title bar; only this fixes the taskbar.
    public static class Shell
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SetCurrentProcessExplicitAppUserModelID(
            [MarshalAs(UnmanagedType.LPWStr)] string AppID);

        // Must be called before the first window is created. Failing is not
        // worth stopping startup for: the app still runs, it just borrows the
        // host's taskbar identity.
        public static bool SetAppId(string id)
        {
            try
            {
                SetCurrentProcessExplicitAppUserModelID(id);
                return true;
            }
            catch
            {
                return false;
            }
        }
    }

    // Base class giving change notification without repeating boilerplate.
    public class Observable : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;

        protected void Raise(string name)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(name));
        }

        public void Notify(string name) { Raise(name); }
    }

    // One debloat option. Selection lives in State, which is deliberately empty
    // on load so that nothing is ever selected by default.
    public class TweakVM : Observable
    {
        private string _state = "";
        private string _currentState = "Unknown";
        private bool _isExpanded;
        private bool _isVisible = true;
        private bool _isTouched;

        public string Id { get; set; }
        public string Name { get; set; }
        public string Category { get; set; }
        public string CategoryName { get; set; }
        public string Risk { get; set; }
        public string Impact { get; set; }
        public string Explain { get; set; }
        public string EnableMeans { get; set; }
        public string DisableMeans { get; set; }
        public string RevertMeans { get; set; }
        public string ActionSummary { get; set; }
        public string Docs { get; set; }
        public bool RequiresRestart { get; set; }
        public bool RequiresSignOut { get; set; }
        public string SearchBlob { get; set; }

        // "", "Enable", "Disable" or "Revert".
        public string State
        {
            get { return _state; }
            set
            {
                if (_state == value) return;
                _state = value;
                Raise("State");
                Raise("HasSelection");
                Raise("SelectionGlyph");
            }
        }

        public bool HasSelection { get { return !string.IsNullOrEmpty(_state); } }

        public string SelectionGlyph
        {
            get
            {
                if (_state == "Enable") return "\uE73E";
                if (_state == "Disable") return "\uE711";
                if (_state == "Revert") return "\uE777";
                return "";
            }
        }

        // Live state detected on this machine: Enabled / Disabled / Mixed / Unknown.
        public string CurrentState
        {
            get { return _currentState; }
            set { if (_currentState == value) return; _currentState = value; Raise("CurrentState"); }
        }

        // True once this app has changed the option, so a Revert is meaningful.
        public bool IsTouched
        {
            get { return _isTouched; }
            set { if (_isTouched == value) return; _isTouched = value; Raise("IsTouched"); }
        }

        public bool IsExpanded
        {
            get { return _isExpanded; }
            set { if (_isExpanded == value) return; _isExpanded = value; Raise("IsExpanded"); }
        }

        public bool IsVisible
        {
            get { return _isVisible; }
            set { if (_isVisible == value) return; _isVisible = value; Raise("IsVisible"); }
        }

        public string RiskLabel
        {
            get
            {
                if (Risk == "safe") return "Safe";
                if (Risk == "moderate") return "Moderate";
                if (Risk == "aggressive") return "Aggressive";
                return "Unknown";
            }
        }

        // Assistive technology reads the item's string form, so without this a
        // screen reader announces "Debloat.TweakVM" instead of the option name.
        public override string ToString()
        {
            string s = Name;
            if (!string.IsNullOrEmpty(RiskLabel)) s += ", " + RiskLabel + " risk";
            if (!string.IsNullOrEmpty(CurrentState)) s += ", currently " + CurrentState;
            if (HasSelection) s += ", set to " + State;
            return s;
        }
    }

    // A left-rail category.
    public class CategoryVM : Observable
    {
        private int _pending;
        private bool _isSelected;

        public string Key { get; set; }
        public string Name { get; set; }
        public string Glyph { get; set; }
        public string Blurb { get; set; }
        public int Total { get; set; }

        public int Pending
        {
            get { return _pending; }
            set { if (_pending == value) return; _pending = value; Raise("Pending"); Raise("HasPending"); }
        }

        public bool HasPending { get { return _pending > 0; } }

        public bool IsSelected
        {
            get { return _isSelected; }
            set { if (_isSelected == value) return; _isSelected = value; Raise("IsSelected"); }
        }

        // How much of this category is already switched off. Options whose live
        // state could not be read are left out of both halves rather than being
        // guessed at, so the figure never overstates what is known.
        private int _offCount;
        private int _knownCount;

        public int OffCount
        {
            get { return _offCount; }
            set { if (_offCount == value) return; _offCount = value; RaiseCoverage(); }
        }

        public int KnownCount
        {
            get { return _knownCount; }
            set { if (_knownCount == value) return; _knownCount = value; RaiseCoverage(); }
        }

        private void RaiseCoverage()
        {
            Raise("OffCount"); Raise("KnownCount"); Raise("Coverage");
            Raise("CoverageRest"); Raise("CoverageText"); Raise("HasCoverage");
        }

        public double Coverage
        {
            get { return _knownCount <= 0 ? 0 : (double)_offCount / _knownCount; }
        }

        public double CoverageRest { get { return 1.0 - Coverage; } }

        public bool HasCoverage { get { return _knownCount > 0 && _offCount > 0; } }

        public string CoverageText
        {
            get
            {
                if (_knownCount <= 0) return "state not known";
                return _offCount + " of " + _knownCount + " off";
            }
        }

        public int Percent
        {
            get { return _knownCount <= 0 ? 0 : (int)System.Math.Round(Coverage * 100.0); }
        }

        public override string ToString()
        {
            string s = Name;
            if (Total > 0) s += ", " + Total + " options";
            if (_pending > 0) s += ", " + _pending + " staged";
            return s;
        }
    }

    // A built-in or user-authored preset.
    public class PresetVM : Observable
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Summary { get; set; }
        public string Detail { get; set; }
        public string Risk { get; set; }
        public string Glyph { get; set; }
        public string Origin { get; set; }
        public string Path { get; set; }
        public int EnableCount { get; set; }
        public int DisableCount { get; set; }
        public int RevertCount { get; set; }
        public string Categories { get; set; }
        public string Warning { get; set; }

        public bool HasWarning { get { return !string.IsNullOrEmpty(Warning); } }
        public bool IsUserPreset { get { return Origin == "user"; } }

        public string CountSummary
        {
            get
            {
                return DisableCount + " to disable  \u00B7  " + EnableCount + " to enable  \u00B7  " + RevertCount + " to revert";
            }
        }

        public string RiskLabel
        {
            get
            {
                if (Risk == "safe") return "Safe";
                if (Risk == "moderate") return "Moderate";
                if (Risk == "aggressive") return "Aggressive";
                return "Mixed";
            }
        }

        // Tier gating. A locked preset still shows its full description - you
        // can read exactly what you would be buying before you buy it.
        private bool _locked;

        public string Tier { get; set; }

        public bool IsLocked
        {
            get { return _locked; }
            set { if (_locked == value) return; _locked = value; Raise("IsLocked"); Raise("IsUnlocked"); Raise("StageLabel"); }
        }

        public bool IsUnlocked { get { return !_locked; } }

        public string StageLabel { get { return _locked ? "Unlock with Pro" : "Stage selections"; } }

        public override string ToString()
        {
            string s = Name + ", " + RiskLabel + " risk. " + CountSummary;
            if (_locked) s += " Requires Pro.";
            return s;
        }
    }

    // A single line in the apply/undo activity log.
    public class LogVM
    {
        public string Time { get; set; }
        public string Level { get; set; }
        public string Text { get; set; }

        public override string ToString() { return Time + " " + Text; }
    }

    // A staged change shown in the confirmation sheet.
    public class ChangeVM
    {
        public string Name { get; set; }
        public string Action { get; set; }
        public string Category { get; set; }
        public string Risk { get; set; }
        public string Detail { get; set; }
        public bool RequiresRestart { get; set; }

        public override string ToString()
        {
            return Action + " " + Name + " (" + Category + "). " + Detail;
        }
    }

    // Header/footer state shared across the window.
    public class ShellVM : Observable
    {
        private int _pendingTotal;
        private int _journalCount;
        private bool _isBusy;
        private string _busyTitle = "";
        private string _busyDetail = "";
        private double _progress;
        private string _status = "Ready";
        private string _adminText = "";
        private string _sectionTitle = "";
        private string _sectionBlurb = "";
        private bool _restartPending;

        public int PendingTotal
        {
            get { return _pendingTotal; }
            set
            {
                if (_pendingTotal == value) return;
                _pendingTotal = value;
                Raise("PendingTotal"); Raise("HasPending"); Raise("PendingText");
            }
        }
        public bool HasPending { get { return _pendingTotal > 0; } }
        public string PendingText
        {
            get
            {
                if (_pendingTotal == 0) return "No changes staged";
                if (_pendingTotal == 1) return "1 change staged";
                return _pendingTotal + " changes staged";
            }
        }

        public int JournalCount
        {
            get { return _journalCount; }
            set
            {
                if (_journalCount == value) return;
                _journalCount = value;
                Raise("JournalCount"); Raise("CanUndo"); Raise("UndoText");
            }
        }
        public bool CanUndo { get { return _journalCount > 0; } }
        public string UndoText
        {
            get
            {
                if (_journalCount == 0) return "Nothing to undo yet";
                if (_journalCount == 1) return "Undo all changes (1 recorded)";
                return "Undo all changes (" + _journalCount + " recorded)";
            }
        }

        public bool IsBusy
        {
            get { return _isBusy; }
            set { if (_isBusy == value) return; _isBusy = value; Raise("IsBusy"); Raise("NotBusy"); }
        }
        public bool NotBusy { get { return !_isBusy; } }

        public string BusyTitle
        {
            get { return _busyTitle; }
            set { _busyTitle = value; Raise("BusyTitle"); }
        }
        public string BusyDetail
        {
            get { return _busyDetail; }
            set { _busyDetail = value; Raise("BusyDetail"); }
        }
        public double Progress
        {
            get { return _progress; }
            set { _progress = value; Raise("Progress"); }
        }
        public string Status
        {
            get { return _status; }
            set { _status = value; Raise("Status"); }
        }
        public string AdminText
        {
            get { return _adminText; }
            set { _adminText = value; Raise("AdminText"); }
        }
        public string SectionTitle
        {
            get { return _sectionTitle; }
            set { _sectionTitle = value; Raise("SectionTitle"); }
        }
        public string SectionBlurb
        {
            get { return _sectionBlurb; }
            set { _sectionBlurb = value; Raise("SectionBlurb"); }
        }
        public bool RestartPending
        {
            get { return _restartPending; }
            set { if (_restartPending == value) return; _restartPending = value; Raise("RestartPending"); }
        }

        // Licence tier, shown as a quiet chip in the title bar. Never a nag.
        private string _tierName = "Free";
        private bool _isPaid;
        private string _licenceDetail = "";

        public string TierName
        {
            get { return _tierName; }
            set { if (_tierName == value) return; _tierName = value; Raise("TierName"); }
        }

        public bool IsPaid
        {
            get { return _isPaid; }
            set { if (_isPaid == value) return; _isPaid = value; Raise("IsPaid"); Raise("IsFree"); }
        }

        public bool IsFree { get { return !_isPaid; } }

        public string LicenceDetail
        {
            get { return _licenceDetail; }
            set { _licenceDetail = value; Raise("LicenceDetail"); }
        }
    }

    // ---------------------------------------------------------------- converters

    // Two-way string equality: drives the Enable / Disable / Revert radio segments.
    public class StateEqualsConverter : IValueConverter
    {
        public object Convert(object value, Type t, object parameter, CultureInfo c)
        {
            string s = value as string;
            string p = parameter as string;
            return string.Equals(s, p, StringComparison.Ordinal);
        }
        public object ConvertBack(object value, Type t, object parameter, CultureInfo c)
        {
            if (value is bool && (bool)value) return parameter as string;
            return Binding.DoNothing;
        }
    }

    // Risk is a status scale, not a series, so it uses reserved status steps.
    // These were picked by measurement rather than eye: under simulated
    // protanopia the safe/moderate pair separates by dE 11.3 here, against 7.1
    // for the brighter colours this replaced, so the two are still tellable
    // apart by a red-green colourblind reader. Every use pairs them with a
    // label, never colour alone.
    public class RiskBrushConverter : IValueConverter
    {
        public static readonly Color Safe = Color.FromRgb(0x0C, 0xA3, 0x0C);        // status good
        public static readonly Color Moderate = Color.FromRgb(0xFA, 0xB2, 0x19);    // status warning
        public static readonly Color Aggressive = Color.FromRgb(0xD0, 0x3B, 0x3B);  // status critical
        public static readonly Color Neutral = Color.FromRgb(0x8A, 0x93, 0xA6);

        public object Convert(object value, Type t, object parameter, CultureInfo c)
        {
            string s = value as string;
            if (s == "safe") return new SolidColorBrush(Safe);
            if (s == "moderate") return new SolidColorBrush(Moderate);
            if (s == "aggressive") return new SolidColorBrush(Aggressive);
            return new SolidColorBrush(Neutral);
        }
        public object ConvertBack(object value, Type t, object p, CultureInfo c) { return Binding.DoNothing; }
    }

    // Turns a 0..1 proportion into a star GridLength, so a bar can be drawn as
    // two grid columns and stay correct at any window width without code.
    public class DoubleToStarConverter : IValueConverter
    {
        public object Convert(object value, Type t, object parameter, CultureInfo c)
        {
            double d = 0;
            if (value != null) { try { d = System.Convert.ToDouble(value, CultureInfo.InvariantCulture); } catch { } }
            if (double.IsNaN(d) || double.IsInfinity(d) || d < 0) d = 0;
            return new GridLength(d, GridUnitType.Star);
        }
        public object ConvertBack(object value, Type t, object p, CultureInfo c) { return Binding.DoNothing; }
    }

    public class CurrentStateBrushConverter : IValueConverter
    {
        public object Convert(object value, Type t, object parameter, CultureInfo c)
        {
            string s = value as string;
            if (s == "Enabled") return new SolidColorBrush(Color.FromRgb(0x6C, 0xB8, 0xFF));
            if (s == "Disabled") return new SolidColorBrush(Color.FromRgb(0x3D, 0xD6, 0x8C));
            if (s == "Mixed") return new SolidColorBrush(Color.FromRgb(0xF7, 0xB7, 0x4A));
            return new SolidColorBrush(Color.FromRgb(0x76, 0x80, 0x94));
        }
        public object ConvertBack(object value, Type t, object p, CultureInfo c) { return Binding.DoNothing; }
    }

    public class BoolToVisibilityConverter : IValueConverter
    {
        public object Convert(object value, Type t, object parameter, CultureInfo c)
        {
            bool b = value is bool && (bool)value;
            if (string.Equals(parameter as string, "invert", StringComparison.OrdinalIgnoreCase)) b = !b;
            return b ? Visibility.Visible : Visibility.Collapsed;
        }
        public object ConvertBack(object value, Type t, object p, CultureInfo c) { return Binding.DoNothing; }
    }

    public class StringToVisibilityConverter : IValueConverter
    {
        public object Convert(object value, Type t, object parameter, CultureInfo c)
        {
            bool empty = string.IsNullOrWhiteSpace(value as string);
            bool invert = string.Equals(parameter as string, "invert", StringComparison.OrdinalIgnoreCase);
            bool show = invert ? empty : !empty;
            return show ? Visibility.Visible : Visibility.Collapsed;
        }
        public object ConvertBack(object value, Type t, object p, CultureInfo c) { return Binding.DoNothing; }
    }

    public class LogBrushConverter : IValueConverter
    {
        public object Convert(object value, Type t, object parameter, CultureInfo c)
        {
            string s = value as string;
            if (s == "error") return new SolidColorBrush(Color.FromRgb(0xFF, 0x6F, 0x7A));
            if (s == "warn") return new SolidColorBrush(Color.FromRgb(0xF7, 0xB7, 0x4A));
            if (s == "ok") return new SolidColorBrush(Color.FromRgb(0x3D, 0xD6, 0x8C));
            if (s == "head") return new SolidColorBrush(Color.FromRgb(0xE8, 0xEC, 0xF4));
            return new SolidColorBrush(Color.FromRgb(0x98, 0xA2, 0xB6));
        }
        public object ConvertBack(object value, Type t, object p, CultureInfo c) { return Binding.DoNothing; }
    }

    public class ActionBrushConverter : IValueConverter
    {
        public object Convert(object value, Type t, object parameter, CultureInfo c)
        {
            string s = value as string;
            if (s == "Enable") return new SolidColorBrush(Color.FromRgb(0x6C, 0xB8, 0xFF));
            if (s == "Disable") return new SolidColorBrush(Color.FromRgb(0xFF, 0x9A, 0x6B));
            if (s == "Revert") return new SolidColorBrush(Color.FromRgb(0xB9, 0x8C, 0xFF));
            return new SolidColorBrush(Color.FromRgb(0x98, 0xA2, 0xB6));
        }
        public object ConvertBack(object value, Type t, object p, CultureInfo c) { return Binding.DoNothing; }
    }
}
