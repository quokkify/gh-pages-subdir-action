export default {
  name: "GitHub Pages Subdirectory Action",
  output: "./allure-report",
  historyPath: "./allure-history/history.jsonl",
  historyLimit: 20,
  plugins: {
    awesome: {
      options: {
        reportName: "GitHub Pages Subdirectory Action test report",
        singleFile: false,
        reportLanguage: "en",
        groupBy: ["epic", "feature", "story"],
      },
    },
  },
};
