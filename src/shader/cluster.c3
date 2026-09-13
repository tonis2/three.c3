<*
 Conservative Forward+ light binning, as a `ShaderDef`.

 `shaders/cluster.shady` is the module: one invocation per cluster, the dispatch
 it is built for, and the body. This file holds the push block - `ClusterPush`,
 walked - and nothing else, because nothing else is C3's to know.
*>
module three;

import shady;

macro ShaderDef cluster_def()
{
	ShaderSource[] sources = {
		{ .name = "cluster", .file = ShaderFile.CLUSTER_SHADY },
	};

	return (ShaderDef) { .name = "cluster", .sources = sources };
}
