using System;
using System.Globalization;
using System.Windows;

namespace Melcosoft.Localization
{
    internal static class LocalizationHelper
    {
        public static void LoadLanguage(string language)
        {
            var dict = new ResourceDictionary();

            string file = language switch
            {
                "ru_RU" => "Localization/ru_RU.xaml",
                "uk_UA" => "Localization/uk_UA.xaml",
                "fr_FR" => "Localization/fr_FR.xaml",
                "de_DE" => "Localization/de_DE.xaml",
                _ => "Localization/en_US.xaml"
            };

            dict.Source = new Uri($"pack://application:,,,/Melcosoft;component/{file}", UriKind.Absolute);

            Application.Current.Resources.MergedDictionaries.Clear();
            Application.Current.Resources.MergedDictionaries.Add(dict);
        }

        public static string LocalizePhase(string phase)
        {
            switch ((phase ?? string.Empty).Trim().ToUpperInvariant())
            {
                case "CONNECTING":
                    return Loc.Connecting;
                case "DOWNLOADING":
                    return Loc.DownloadingFiles;
                case "EXTRACTING":
                    return Loc.ExtractingFiles;
                case "VALIDATING":
                    return Loc.ValidatingFiles;
                case "FINALIZING":
                    return Loc.FinalizingInstallation;
                case "PREPARING":
                case "PREPARING_DOWNLOAD":
                    return Loc.PreparingDownload;
                default:
                    return Loc.Working;
            }
        }

        public static string LocalizeState(string state)
        {
            switch ((state ?? string.Empty).Trim().ToUpperInvariant())
            {
                case "QUEUED":
                    return Loc.Queued;
                case "RUNNING":
                    return Loc.Running;
                case "PAUSING":
                    return Loc.Pausing;
                case "PAUSED":
                    return Loc.Paused;
                case "CANCELLING":
                case "CANCELING":
                    return Loc.Cancelling;
                case "CANCELLED":
                case "CANCELED":
                    return Loc.Cancelled;
                case "SUCCEEDED":
                    return Loc.Completed;
                case "FAILED":
                    return Loc.Failed;
                default:
                    return Loc.Working;
            }
        }
    }
}
