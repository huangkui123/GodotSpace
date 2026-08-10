# PC Ground Server owns the reconstruction map

The Sky Physical Space is the real-world reference, but the PC Ground Server is the sole authority for accepted registration state, visual reconstruction map versions, caching, resets, and publication to participants. The lab reconstruction worker only produces inference results, and Sky and Ground clients do not connect to it directly; the extra relay hop is accepted to preserve one consistent map and make reconnect recovery possible.
