# plan_dot renders the focal/reduce pipeline

    Code
      cat(plan_dot(p))
    Output
      digraph plan {
        rankdir=LR;
        s1 [shape=cylinder, label="[1] source_read\nnodes: 1\nhalo: 1"];
        s2 [shape=box, label="[2] compute\nnodes: 2,3\nhalo: 1"];
        s3 [shape=trapezium, label="[3] reduce_partial\nnodes: 4\nhalo: 0"];
        s4 [shape=invtrapezium, label="[4] reduce_combine\nnodes: 4\nhalo: 0"];
        s1 -> s2;
        s2 -> s3;
        s3 -> s4;
        s4 [penwidth=2];
      }

# plan_dot renders the NDVI pipeline

    Code
      cat(plan_dot(p))
    Output
      digraph plan {
        rankdir=LR;
        s1 [shape=cylinder, label="[1] source_read\nnodes: 1\nhalo: 0"];
        s2 [shape=cylinder, label="[2] source_read\nnodes: 2\nhalo: 0"];
        s3 [shape=box, label="[3] compute\nnodes: 3,4,5\nhalo: 0"];
        s1 -> s3;
        s2 -> s3;
        s3 [penwidth=2];
      }

