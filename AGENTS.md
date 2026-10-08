# Pull request review evidence

Every pull request must include a screenshot or short video that shows what the
implemented change does or how to use it. Put the image or video directly in the
PR description so a reviewer can assess the behavior without downloading a build.

- Capture the working application. Show the relevant interaction and result;
  use a before/after sequence or video when one still image cannot explain it.
- Include evidence for each platform whose visible behavior changes. Identify
  the platform and the source commit used for the capture.
- Native application windows driven by automated review fixtures are acceptable;
  label fixture inputs and automated interaction clearly. Mockups and generated
  illustrations are not evidence that the feature works.
- For internal changes, show the relevant measured or validation result. For
  documentation changes, show the rendered content that changed.
- Keep captures focused and free of personal information. Store durable evidence
  in `docs/review/<change>/` or attach it to the PR; temporary CI artifacts alone
  do not provide a lasting review record.

Run the checks appropriate to the change and describe them separately from the
visual evidence. A screenshot is useful for review but does not replace tests.
