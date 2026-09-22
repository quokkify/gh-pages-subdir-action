export default {
  name: "GitHub Pages Subdirectory Action",
  output: "./allure-report",
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
