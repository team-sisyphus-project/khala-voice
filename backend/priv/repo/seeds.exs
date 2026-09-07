# Seeds for development and first-time installs.
#
#     mix run priv/repo/seeds.exs
#
# `mix ecto.setup` runs this automatically. Safe to run multiple times.
#
# **The logic is in `VR.Release.seed/1`, not here.** A built release has no Mix
# and so cannot run this file, while the deploy's seed step has to create
# exactly what this file creates. Two entry points, one copy — the release
# module is the one that can be reached from both.
#
# **Never seed the test DB.** Tests assume an empty DB and create their own data.
# If `MIX_ENV=test mix ecto.reset` ran the seeds too, the free plan would be
# duplicated and the billing tests would break wholesale.

if Mix.env() == :test do
  IO.puts("[seeds] not seeding in the test environment")
  System.halt(0)
end

# The entry point is passed in: the messages tell the operator which command to
# run again, and from here that command is this file, not `bin/vr eval`.
VR.Release.seed(entry_point: "mix run priv/repo/seeds.exs")
